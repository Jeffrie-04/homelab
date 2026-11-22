# Secret leak remediation: rotate, reseal, purge

**What happened:** plaintext credentials were committed to this public repo
(Immich DB password, Nextcloud admin/DB/Redis password, and an early
plain (unsealed) Immich Postgres Secret). They're in 26 places across history.

**Order matters:**
1. Rotate (makes the leaked values useless)
2. Ship the code that reads from SealedSecrets
3. Purge history (only removes them from GitHub going forward)

Deleting from history without rotating is not a fix. Anyone who cloned
before still has them.

Expect about 5 minutes of downtime per app. Run everything from the repo root on the Mac.

---

## 0. Prereqs

```bash
brew install kubeseal git-filter-repo pre-commit
git checkout remove-plaintext-secrets      # or wherever you applied the patch
kubectl get pods -n kube-system | grep sealed-secrets   # note the controller name
helm list -n nextcloud                     # note RELEASE name + CHART version
```

If the controller isn't `sealed-secrets-controller` in `kube-system`, export
`SS_NAME` and `SS_NS` before step 1. If the Nextcloud release isn't named
`nextcloud`, export `NC_RELEASE` and adjust the pod names below.

## 1. Generate + seal new credentials

```bash
./scripts/rotate-secrets.sh
source ~/.homelab-rotation.env
```

This rewrites `apps/immich/postgres-secret.yaml` and creates
`apps/nextcloud/sealed-secret.yaml`. Only ciphertext goes in git.

## 2. Immich

```bash
# a) Push the new secret into the cluster
kubectl apply -f apps/immich/postgres-secret.yaml

# b) Change the DB user's password. \password hashes client-side, so the
#    plaintext never shows up in Postgres logs.
echo -n "$IMMICH_DB_PASSWORD" | pbcopy
kubectl exec -it -n immich immich-postgres-1 -- psql -U postgres
#   postgres=# \password immich      (paste twice)
#   postgres=# \q

# c) Point Immich at the secret. The Application CR isn't managed by Argo
#    itself, so changing it in git does nothing until you apply it.
kubectl apply -f apps/argocd-apps/immich-app.yaml
kubectl rollout status -n immich deploy/immich-server

# d) Remove the old, unused duplicate secret
kubectl get pods -n immich -o yaml | grep -c immich-db-credentials   # expect 0
kubectl delete sealedsecret immich-db-credentials -n immich
```

Check that you can open Immich at :2283 and that photos load.

## 3. Nextcloud

```bash
kubectl apply -f apps/nextcloud/sealed-secret.yaml
kubectl get secret nextcloud-credentials -n nextcloud    # wait until it exists

occ() { kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
          su -s /bin/sh www-data -c "php /var/www/html/occ $*"; }

# a) Maintenance mode, then update the DB password in config.php.
#    config.php lives on the PVC and is NOT regenerated from env vars.
occ maintenance:mode --on
occ config:system:set dbpassword --value="$NC_DB_PASSWORD"

# b) Change the DB user's password in Postgres (log in as that user with the
#    OLD password, which the pod already has)
echo -n "$NC_DB_PASSWORD" | pbcopy
kubectl exec -it -n nextcloud nextcloud-postgresql-0 -- bash -c \
  'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/password 2>/dev/null || echo "$POSTGRES_PASSWORD")" psql -U nextcloud -d nextcloud'
#   nextcloud=> \password           (paste twice)
#   nextcloud=> \q
# If login fails: exec in with bash and run `env | grep -i pass` to find it.

# c) Redeploy with existingSecret values. PIN the current chart version
#    from `helm list`, or you'll get an unplanned Nextcloud major upgrade.
helm upgrade nextcloud nextcloud/nextcloud -n nextcloud \
  --version <CURRENT_CHART_VERSION> -f apps/nextcloud/values.yaml
kubectl rollout status -n nextcloud deploy/nextcloud
kubectl rollout status -n nextcloud statefulset/nextcloud-redis-master

# d) Reset the web admin password. The chart only uses it at first install.
kubectl exec -n nextcloud deploy/nextcloud -c nextcloud -- \
  env OC_PASS="$NC_ADMIN_PASSWORD" su -p -s /bin/sh www-data -c \
  'php /var/www/html/occ user:resetpassword --password-from-env admin'

occ maintenance:mode --off
occ status
```

Log in at :8080 with the new admin password. Phone and desktop clients may
ask you to sign in again.

If the rotation script warned that it generated a new Postgres superuser
password, also run `ALTER USER postgres` as a superuser, or the secret won't
match reality.

## 4. Ship the code + guardrails

```bash
git add -A && git commit -m "security: rotate credentials (sealed)"
git push -u origin remove-plaintext-secrets    # then merge to main
pre-commit install                            # local block on future leaks
```

Also turn on **Secret scanning** and **Push protection** in the repo's
GitHub security settings. Both are free for public repos.

## 5. Purge history

Run this only after step 4 is merged to `main`:

```bash
./scripts/purge-history.sh
```

It clones fresh, rewrites every commit so any literal `password:` /
`DB_PASSWORD:` value becomes `REDACTED` (SealedSecret ciphertext is kept),
verifies nothing is left, and asks before force-pushing. Commits whose only
change was a password value become empty and are dropped. That's expected.

Afterwards:
- **Re-clone** on every machine with a copy. Don't `git pull` old clones,
  or the old history can get pushed back.
- `gh api repos/Jeffrie-04/homelab/forks --jq length`: forks keep old history.
- GitHub can still serve old commits by SHA from its cache for a while. To
  purge that, contact GitHub Support (see GitHub's "Removing sensitive data
  from a repository" docs). Rotation already made those values useless.

## 6. Clean up

- Save the new Nextcloud admin password in your password manager.
- `rm ~/.homelab-rotation.env`
- If the old Nextcloud password was reused **anywhere else**, change it there.
