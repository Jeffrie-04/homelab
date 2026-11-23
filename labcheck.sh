#!/usr/bin/env bash
# labcheck.sh — bottom-up health check for the homelab.
# Run from the Mac:  ./labcheck.sh
# Layers: hosts -> quorum -> VMs -> storage -> k3s nodes -> platform pods -> ArgoCD -> endpoints
# Exit code = number of failed checks (0 = all good).

set -uo pipefail

# ---- inventory (edit to match the lab) ----
PVE_NODES=(192.168.1.10 192.168.1.11 192.168.1.12 192.168.1.13)
K3S_VMS=(192.168.1.50 192.168.1.51 192.168.1.52 192.168.1.53)
SSH_USER=root
NFS_CHECKS=(              # "host:mountpoint"
  "192.168.1.12:/mnt/immich-data"
  "192.168.1.13:/mnt/nextcloud-data-v2"
)
ENDPOINTS=(               # "name|url"  (k3s ServiceLB answers on node IPs)
  "Immich|http://192.168.1.50:2283/api/server/ping"
  "Nextcloud|http://192.168.1.50:8080/status.php"
)
MINECRAFT="192.168.1.10:25565"

# ---- helpers ----
FAILS=0
ok()   { printf "  \033[32m✅\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m❌\033[0m %s\n" "$1"; FAILS=$((FAILS+1)); }
hdr()  { printf "\n\033[1m%s\033[0m\n" "$1"; }
SSH()  { ssh -o ConnectTimeout=3 -o BatchMode=yes "$SSH_USER@$1" "${@:2}" 2>/dev/null; }
# macOS ping uses -t (seconds); Linux uses -W
if [[ "$(uname)" == "Darwin" ]]; then PING="ping -c1 -t 2"; else PING="ping -c1 -W 2"; fi

# 1. Hosts reachable?
hdr "1. Proxmox hosts"
UP_NODE=""
for ip in "${PVE_NODES[@]}"; do
  if $PING "$ip" >/dev/null 2>&1; then ok "$ip up"; UP_NODE=${UP_NODE:-$ip}; else bad "$ip DOWN"; fi
done

# 2. Cluster quorum (ask any node that's up)
hdr "2. Proxmox quorum"
if [[ -n "$UP_NODE" ]] && SSH "$UP_NODE" "pvecm status" | grep -q "Quorate:.*Yes"; then
  ok "cluster quorate (asked $UP_NODE)"
else
  bad "not quorate or couldn't ask (try: pvecm status)"
fi

# 3. K3s VMs reachable?
hdr "3. K3s VMs"
for ip in "${K3S_VMS[@]}"; do
  if $PING "$ip" >/dev/null 2>&1; then ok "$ip up"; else bad "$ip DOWN (VM not started? check qm list)"; fi
done

# 4. Storage: NFS mounts present on the storage nodes
hdr "4. Storage (NFS / DAS)"
for entry in "${NFS_CHECKS[@]}"; do
  host=${entry%%:*}; path=${entry#*:}
  if SSH "$host" "mountpoint -q $path && timeout 5 ls $path >/dev/null"; then
    ok "$host:$path mounted and readable"
  else
    bad "$host:$path missing/stale (DAS powered? check exportfs -v)"
  fi
done

# 5. K3s nodes Ready?
hdr "5. K3s nodes"
if NODES=$(kubectl get nodes --no-headers 2>/dev/null); then
  while read -r name status _; do
    [[ "$status" == "Ready" ]] && ok "$name Ready" || bad "$name $status"
  done <<< "$NODES"
else
  bad "kubectl can't reach the API server (k3s-server down?)"
fi

# 6. Platform + app pods not healthy
hdr "6. Pods (not running, not ready, or crash-looping)"
if ! ALLPODS=$(kubectl get pods -A --no-headers 2>/dev/null) || [[ -z "$ALLPODS" ]]; then
  bad "couldn't list pods (API unreachable) — result unknown, not healthy"
else
  # Flag: status not Running/Completed, OR Running but not fully ready (0/1),
  # OR an active crash loop: > RESTART_LIMIT restarts AND the last one < 10 min ago.
  # CrashLoopBackOff caps at 5 min between restarts, so a live loop always restarted
  # within ~6 min. kubectl shows "(20s ago)" / "(6m59s ago)" / "(47m ago)" / "(83d ago)".
  RESTART_LIMIT=5
  RECENT_MIN=10
  BADPODS=$(awk -v lim="$RESTART_LIMIT" -v rmin="$RECENT_MIN" '{
      split($3, r, "/"); st=$4; rs=$5+0
      if (st == "Completed") next
      ago = $6; sub(/^\(/, "", ago)
      recent = 0
      if (rs > 0 && ago ~ /^[0-9]+s/) recent = 1                      # seconds ago
      if (rs > 0 && ago ~ /^[0-9]+m/ && ago+0 < rmin) recent = 1      # minutes ago, under limit
      if (st != "Running" || r[1] != r[2] || (rs > lim && recent)) print
    }' <<< "$ALLPODS")
  if [[ -z "$BADPODS" ]]; then ok "all pods healthy"; else
    while read -r line; do bad "$line"; done <<< "$BADPODS"
  fi
fi

# 7. ArgoCD apps synced + healthy
hdr "7. ArgoCD applications"
APPS=$(kubectl get applications -n argocd --no-headers \
  -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status 2>/dev/null)
if [[ -z "$APPS" ]]; then bad "couldn't list ArgoCD apps"; else
  while read -r name sync health; do
    [[ "$sync" == "Synced" && "$health" == "Healthy" ]] && ok "$name" || bad "$name ($sync / $health)"
  done <<< "$APPS"
fi

# 8. User-facing endpoints
hdr "8. Endpoints"
for entry in "${ENDPOINTS[@]}"; do
  name=${entry%%|*}; url=${entry#*|}
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$url")
  [[ "$code" =~ ^2|^3 ]] && ok "$name ($code)" || bad "$name not responding ($code) — $url"
done
if nc -z -G 3 "${MINECRAFT%:*}" "${MINECRAFT#*:}" 2>/dev/null || nc -z -w 3 "${MINECRAFT%:*}" "${MINECRAFT#*:}" 2>/dev/null; then
  ok "Minecraft port open"
else
  bad "Minecraft not answering on $MINECRAFT (docker ps on pve1)"
fi

# ---- summary ----
echo
if (( FAILS == 0 )); then echo "🟢 All checks passed."; else echo "🔴 $FAILS check(s) failed — fix the LOWEST-numbered layer first."; fi
exit "$FAILS"