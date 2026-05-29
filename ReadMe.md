# Homelab — Proxmox + K3s

A 4-node homelab running Proxmox VE with a K3s Kubernetes cluster and full monitoring stack. Built to self-host services and develop hands-on DevOps skills.

---

## Hardware

| Host | Machine | IP |
|------|---------|-----|
| pve1 | Dell OptiPlex 7070 Micro | 192.168.1.10 |
| pve2 | HP EliteDesk 800 G4 | 192.168.1.11 |
| pve3 | Lenovo M920q #1 | 192.168.1.12 |
| pve4 | Lenovo M920q #2 | 192.168.1.13 |

---

## Architecture

```
Proxmox VE Cluster ("homelab")
├── pve1 → k3s-server   (192.168.1.50)
├── pve2 → k3s-worker-1 (192.168.1.51)
├── pve3 → k3s-worker-2 (192.168.1.52)
└── pve4 → k3s-worker-3 (192.168.1.53)
```

---

## Stack

| Layer | Tool |
|-------|------|
| Hypervisor | Proxmox VE 9.x |
| VM Provisioning | Cloud-Init + Ubuntu 22.04 |
| Orchestration | K3s v1.35.5 |
| Package Management | Helm |
| Metrics | Prometheus |
| Dashboards | Grafana |
| Alerting | Alertmanager |

---


