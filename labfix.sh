#!/usr/bin/env bash
# labfix.sh — diagnose-then-fix for the two most common homelab failures:
#   A) Nextcloud DAS/NFS not mounted on pve4
#   B) K3s API unreachable (service down OR stale/expired kubeconfig on the Mac)
# Every fix shows evidence first and asks before acting. Safe to re-run.
# Run from the Mac:  ./labfix.sh     then re-run ./labcheck.sh

set -uo pipefail

# ---- inventory ----
PVE_USER=root
STORAGE_HOST=192.168.1.13
STORAGE_PATH=/mnt/nextcloud-data-v2
K3S_SERVER=192.168.1.50
K3S_USER="${K3S_USER:-ubuntu}"     # SSH user on the k3s VMs — change if yours differs
NEXTCLOUD_NS=nextcloud             # namespace to restart after storage comes back

# ---- helpers ----
hdr()  { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }
info() { printf "  %s\n" "$1"; }
ask()  { read -r -p "  → $1 [y/N] " a; [[ "$a" =~ ^[Yy]$ ]]; }
SSHP() { ssh -o ConnectTimeout=5 "$PVE_USER@$STORAGE_HOST" "$@"; }
SSHK() { ssh -o ConnectTimeout=5 "$K3S_USER@$K3S_SERVER" "$@"; }
STORAGE_FIXED=0

# =====================================================================
hdr "A. Nextcloud storage on pve4 ($STORAGE_HOST:$STORAGE_PATH)"
if SSHP "mountpoint -q $STORAGE_PATH"; then
  info "✅ already mounted — nothing to do"
else
  info "Not mounted. Evidence:"
  info "-- fstab entry:";            SSHP "grep -F '$STORAGE_PATH' /etc/fstab || echo '   (no fstab entry!)'"
  info "-- block devices (is the DAS visible?):"; SSHP "lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop"
  info "-- recent USB/disk kernel messages:";     SSHP "dmesg -T | grep -iE 'usb|sd[a-z]|I/O error' | tail -8"

  # Is the device behind the fstab entry actually present?
  DEV=$(SSHP "findmnt --fstab -n -o SOURCE $STORAGE_PATH" 2>/dev/null)
  if [[ -n "$DEV" ]] && SSHP "blkid -t '${DEV#*=}' >/dev/null 2>&1 || test -b '$DEV'"; then
    info "Device for $STORAGE_PATH ($DEV) is present → safe to mount."
    if ask "mount $STORAGE_PATH and re-export NFS on pve4?"; then
      SSHP "mount $STORAGE_PATH && exportfs -ra && exportfs -v | grep -F '$STORAGE_PATH'" \
        && { info "✅ mounted and exported"; STORAGE_FIXED=1; } \
        || info "❌ mount failed — read the dmesg output above (possible filesystem error → fsck)"
    fi
  else
    info "❌ The DAS disk isn't visible to pve4. This is physical, not software:"
    info "   1) check the DAS is powered on  2) reseat the USB cable  3) re-run this script"
  fi
fi

# =====================================================================
hdr "B. K3s API ($K3S_SERVER:6443)"
CTX_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)
info "kubectl is pointed at: ${CTX_SERVER:-<no context>}"

# Does the API answer at all? (401/403 = up but wants auth; 000 = nothing listening)
CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$K3S_SERVER:6443/livez")
info "API /livez HTTP code: $CODE"

if [[ "$CODE" == "000" ]]; then
  info "Nothing answering on 6443 → k3s service is likely down. Evidence:"
  SSHK "systemctl is-active k3s; sudo journalctl -u k3s --no-pager -n 25" \
    || info "(couldn't SSH as $K3S_USER — set K3S_USER=<you> ./labfix.sh)"
  if ask "restart k3s on k3s-server? (also rotates certs that are near expiry)"; then
    SSHK "sudo systemctl restart k3s && sleep 20 && systemctl is-active k3s"
    CODE=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 5 "https://$K3S_SERVER:6443/livez")
    info "API /livez now: $CODE"
  fi
fi

if [[ "$CODE" != "000" ]] && ! kubectl get --raw /livez >/dev/null 2>&1; then
  info "API is up but kubectl can't authenticate → your Mac's kubeconfig is stale."
  EXP=$(kubectl config view --raw --minify -o jsonpath='{.users[0].user.client-certificate-data}' 2>/dev/null \
        | base64 -d 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)
  info "client cert: ${EXP:-<unreadable>}"
  if ask "back up ~/.kube/config and pull a fresh one from k3s-server?"; then
    cp ~/.kube/config ~/.kube/config.bak.$(date +%Y%m%d-%H%M%S)
    SSHK "sudo cat /etc/rancher/k3s/k3s.yaml" | sed "s/127.0.0.1/$K3S_SERVER/" > ~/.kube/config.new \
      && mv ~/.kube/config.new ~/.kube/config && chmod 600 ~/.kube/config \
      && info "✅ kubeconfig replaced (backup saved next to it)"
  fi
fi

if kubectl get nodes >/dev/null 2>&1; then
  info "✅ kubectl works:"; kubectl get nodes
else
  info "❌ kubectl still can't reach the cluster — paste the output above to debug"
fi

# =====================================================================
# Pods that had the NFS volume while it was missing hold stale handles; bounce them.
if (( STORAGE_FIXED )) && kubectl get ns "$NEXTCLOUD_NS" >/dev/null 2>&1; then
  hdr "C. Restart Nextcloud so it picks up the remounted storage"
  if ask "rollout restart deployments in namespace $NEXTCLOUD_NS?"; then
    kubectl -n "$NEXTCLOUD_NS" rollout restart deployment
  fi
fi

echo; echo "Done. Re-run ./labcheck.sh to confirm."
