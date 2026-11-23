# Homelab — Proxmox + K3s + GitOps
 
A 4-node homelab running Proxmox VE with a K3s Kubernetes cluster. Self-hosted services are deployed through ArgoCD from this repo, secrets are encrypted with Sealed Secrets, and bulk data lives on a 6TB DAS shared out over NFS. I built it to run real services for my home and to get hands-on with the day-to-day work of DevOps and SRE.
 
---
 
## Hardware
 
| Host | Machine | IP | Role |
|------|---------|-----|------|
| pve1 | Dell OptiPlex 7070 Micro | 192.168.1.10 | k3s-server, Minecraft host |
| pve2 | HP EliteDesk 800 G4 | 192.168.1.11 | k3s-worker-1 (ML-capable CPU) |
| pve3 | Lenovo M920q #1 | 192.168.1.12 | k3s-worker-2, Immich NFS storage |
| pve4 | Lenovo M920q #2 | 192.168.1.13 | k3s-worker-3, DAS / Nextcloud NFS storage |
 
| Device | Details |
|--------|---------|
| Switch | TP-Link TL-SG108E (8-port managed) |
| DAS | 6TB, 4-bay USB 3.2 Gen 2 enclosure (SATA) attached to pve4 |
| Router | Verizon Fios (upstream) |
 
---
 
## Architecture
 
```
                    TP-Link TL-SG108E ── Verizon Fios router
                            │
Proxmox VE Cluster ("homelab")
├── pve1 → k3s-server   (192.168.1.50)   + Minecraft (Docker)
├── pve2 → k3s-worker-1 (192.168.1.51)
├── pve3 → k3s-worker-2 (192.168.1.52)   NFS: /mnt/immich-data       (500GB HDD)
└── pve4 → k3s-worker-3 (192.168.1.53)   NFS: /mnt/nextcloud-data-v2 (6TB DAS)
 
GitHub (this repo) ──► ArgoCD ──► K3s cluster
                                   ├── immich      (CNPG Postgres + Valkey)
                                   ├── nextcloud   (Postgres + Redis)
                                   └── monitoring  (kube-prometheus-stack)
```
 
---
 
## Stack
 
| Layer | Tool |
|-------|------|
| Hypervisor | Proxmox VE 9.x |
| VM Provisioning | Cloud-Init + Ubuntu 22.04 |
| Orchestration | K3s v1.35.5 |
| GitOps | ArgoCD |
| Package Management | Helm |
| Secrets | Sealed Secrets (kubeseal) |
| Databases | CloudNativePG (Immich), Bitnami PostgreSQL (Nextcloud) |
| Storage | NFS-backed PersistentVolumes (`Retain` reclaim policy) |
| Metrics / Dashboards / Alerting | Prometheus, Grafana, Alertmanager |
| Config Management | Ansible |
| Backups | restic (Minecraft), Clonezilla (node disk images) |
 
---
 
## Services
 
| Service | What it does | How it runs | Storage | Access |
|---------|--------------|-------------|---------|--------|
| **Immich** v3.0.3 | Photo and video backup (Google Photos replacement) | Helm chart 0.13.1 via ArgoCD; CNPG Postgres 16 with VectorChord; Valkey | 450Gi NFS on pve3 | LoadBalancer `:2283` |
| **Nextcloud** v33 | File sync and sharing | Bitnami Helm chart with bundled PostgreSQL + Redis | 1.7Ti NFS on the pve4 DAS | LoadBalancer `:8080` |
| **Monitoring** | Cluster metrics, dashboards, alerts | kube-prometheus-stack | — | Grafana |
| **Minecraft** | Cobbleverse modpack server | Docker on pve1 (`itzg/minecraft-server`) with `itzg/mc-backup` restic sidecar | Local | `:25565` |
 
---
 
## Storage
 
| Data | Location | Backing disk |
|------|----------|--------------|
| Nextcloud files | `192.168.1.13:/mnt/nextcloud-data-v2` | 1.8TB partition on the 6TB DAS (pve4) |
| Immich library | `192.168.1.12:/mnt/immich-data` | 500GB HDD (pve3) |
| Immich database | CNPG volume (20Gi) | Cluster-local |
| VM disks | Proxmox local storage | 2× 2TB drives |
 
Persistent volumes use `persistentVolumeReclaimPolicy: Retain`, so deleting a PVC or reinstalling an app never deletes the underlying data.
 
---
 
## Repo layout
 
```
apps/
├── argocd-apps/     ArgoCD Application CRs (applied with kubectl apply)
├── immich/          namespace, PV/PVC, CNPG cluster, sealed DB secret
└── nextcloud/       namespace, PV/PVC, Helm values, sealed credentials
docs/
└── SECRET-ROTATION.md   runbook: rotate → reseal → purge git history
scripts/
├── rotate-secrets.sh    generate + seal new credentials
├── purge-history.sh     git-filter-repo scrub of leaked values
└── nic-diag.sh          multi-node NIC hang diagnostics
labcheck.sh          layered health check for the whole lab
labfix.sh            diagnose-then-fix for the two most common failures
nic-offload.yml      Ansible playbook: e1000e hang fix across all nodes
inventory.ini        Ansible inventory for the Proxmox hosts
```
 
---
 
## Operations tooling
 
**`labcheck.sh`** checks the lab from the bottom up: hosts → Proxmox quorum → K3s VMs → NFS/DAS mounts → K3s nodes → pods (including crash loops) → ArgoCD sync and health → service endpoints. The exit code is the number of failed checks, and the output tells you to fix the lowest-numbered failing layer first.
 
**`labfix.sh`** handles the two failures that come up most often: the DAS/NFS mount dropping on pve4, and the K3s API becoming unreachable (either the service is down or the Mac's kubeconfig is stale). It shows evidence before every fix and asks before it acts.
 
**`nic-offload.yml`** is an idempotent Ansible playbook that rolls out the Intel I219-LM NIC fix one node at a time (`serial: 1`). It supports `--check --diff` dry runs and asserts that the fix took effect before moving to the next node.
 
---
 
## Incidents and what I learned
 
**Intel I219-LM "Hardware Unit Hang" (e1000e).** Several nodes dropped off the network at the same timestamp. Because the hangs happened together, I suspected a shared traffic-burst trigger rather than failing hardware. I disabled TSO/GSO/GRO on pve1 as a canary, and it ran 14 days with zero hangs while the other nodes kept hanging. I then codified the fix in Ansible and rolled it out to the rest of the fleet.
 
**Plaintext secrets in a public repo.** Database and admin passwords had been committed to git history. I followed the right order to fix it: rotate every credential first, move apps to read from SealedSecrets, and only then purge history with `git-filter-repo`. I added pre-commit hooks and GitHub push protection to block future leaks. The full runbook is in [`docs/SECRET-ROTATION.md`](docs/SECRET-ROTATION.md).
 
**GitOps drift.** ArgoCD's `selfHeal` reverted manual `kubectl patch` changes. Settings that had been patched by hand, like the Nextcloud LoadBalancer service, now live in `values.yaml` so git stays the source of truth.
 
**Helm chart breaking changes.** Immich chart 0.10+ removed the Postgres subchart, swapped Redis for Valkey, and moved to an OCI registry. I migrated the database to CloudNativePG and now pin chart versions explicitly.
 
**CPU compatibility.** The M920q nodes lack the x86-64-v2 instructions some ML images need, so machine-learning workloads are limited to compatible nodes.
 
---
 
## Roadmap
 
- [ ] Move Minecraft off the pve1 host into an LXC
- [ ] Nightly rsync of Minecraft backups to the DAS
- [ ] Proxmox Backup Server
- [ ] BIOS AC power recovery + VM autostart on pve1
- [ ] WireGuard remote access (LXC + DuckDNS)
- [ ] Navidrome music server, with a link → download → library pipeline
- [ ] Uptime Kuma, plus postgres_exporter and redis_exporter for app-level metrics
- [ ] Gitea (self-hosted git)
- [ ] MikroTik hEX S router for VLAN segmentation and no double NAT
- [ ] ArgoCD app-of-apps so Application CRs are managed by git too
 
