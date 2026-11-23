#!/usr/bin/env bash
# nic-diag.sh — read-only e1000e diagnostic across the Proxmox fleet
# Usage: ./nic-diag.sh

NODES=(192.168.1.10 192.168.1.11 192.168.1.12 192.168.1.13)
IFACE="nic0"

for node in "${NODES[@]}"; do
  echo "=================================================="
  echo "  NODE: $node"
  echo "=================================================="

  ssh -o ConnectTimeout=5 root@"$node" bash -s <<EOF
echo "--- hostname ---"
hostname

echo "--- offload state ($IFACE) ---"
ethtool -k $IFACE 2>/dev/null | grep -E 'tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload'

echo "--- EEE state ($IFACE) ---"
ethtool --show-eee $IFACE 2>/dev/null | grep -E 'EEE status|Advertised|Link partner' || echo "(EEE not reported)"

echo "--- persisted fix present in /etc/network/interfaces? ---"
grep -nE 'ethtool|post-up' /etc/network/interfaces 2>/dev/null || echo "(no ethtool/post-up lines found)"

echo "--- e1000e hang / link events this boot ---"
journalctl -k -b 2>/dev/null | grep -iE 'hang|reset adapter|e1000e|carrier|link down|link up' | tail -n 15 || echo "(none)"

echo "--- rx error counters ---"
ethtool -S $IFACE 2>/dev/null | grep -iE 'rx_crc_errors|rx_errors|rx_missed|rx_long_length_errors|tx_timeout' || echo "(no counters)"
EOF

  echo ""
done
