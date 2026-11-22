#!/usr/bin/env bash
# Rewrite the repo's entire history so no commit contains a plaintext
# password, then (after you confirm) force-push it to GitHub.
#
# Do this AFTER rotating the passwords (docs/SECRET-ROTATION.md).
# Scrubbing history removes them from GitHub going forward, but anyone who
# cloned before can still see them. Only rotation makes them useless.
#
# Requires: git, git-filter-repo (brew install git-filter-repo)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Jeffrie-04/homelab.git}"
WORK="$(mktemp -d)/homelab-clean"
RULES="$(mktemp)"

command -v git-filter-repo >/dev/null || { echo "Install git-filter-repo first"; exit 1; }

# Any literal value on a `password:` / `DB_PASSWORD:` line becomes REDACTED.
# SealedSecret ciphertext (starts with "Ag", hundreds of chars) is left alone.
cat > "$RULES" <<'EOF'
regex:(?m)^([ \t]*(?:DB_PASSWORD|password)[ \t]*:[ \t]*)"(?!Ag[A-Za-z0-9+/]{100})[^"\n]+"==>\1"REDACTED"
regex:(?m)^([ \t]*(?:DB_PASSWORD|password)[ \t]*:[ \t]*)(?!Ag[A-Za-z0-9+/]{100})(?!["{|>])[^\s"]+[ \t]*$==>\1REDACTED
EOF

echo "==> Fresh clone into $WORK"
git clone --quiet --no-local "$REPO_URL" "$WORK"
cd "$WORK"
BEFORE=$(git rev-list --all | wc -l | tr -d ' ')

echo "==> Rewriting history"
git filter-repo --quiet --replace-text "$RULES"

echo "==> Verifying: every password line in every commit"
LEFT=$(git log --all -p | grep -E '^[+ -][ \t]*(DB_PASSWORD|password)[ \t]*:[ \t]*\S' \
        | grep -vE 'REDACTED|:[ \t]*Ag[A-Za-z0-9+/]{100}' || true)
if [ -n "$LEFT" ]; then
  echo "!! Plaintext password lines remain, NOT pushing:"; echo "$LEFT"; exit 1
fi
AFTER=$(git rev-list --all | wc -l | tr -d ' ')
echo "    clean. commits before=$BEFORE after=$AFTER"
echo "    Spot-check: cd $WORK && git log -p -- apps/nextcloud/values.yaml"

read -r -p "Force-push rewritten history to $REPO_URL? Type 'yes': " OK
[ "$OK" = "yes" ] || { echo "Not pushed. Clean copy left at $WORK"; exit 0; }

git remote add origin "$REPO_URL"   # filter-repo removes origin on purpose
git push --force --all origin
git push --force --tags origin
echo "==> Done. Re-clone the repo on every machine that had a copy."
