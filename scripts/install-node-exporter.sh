#!/usr/bin/env bash
set -Eeuo pipefail

COLLECTOR_IP="${COLLECTOR_IP:-10.10.10.222}"

echo "[INFO] Install Node Exporter..."
sudo apt update
sudo apt install -y prometheus-node-exporter curl

echo "[INFO] Enable Node Exporter..."
sudo systemctl enable --now prometheus-node-exporter
sudo systemctl restart prometheus-node-exporter

echo "[INFO] Configure firewall if active..."

if command -v ufw >/dev/null 2>&1; then
  if sudo ufw status | grep -qi active; then
    sudo ufw allow from "${COLLECTOR_IP}" to any port 9100 proto tcp || true
  fi
fi

if command -v firewall-cmd >/dev/null 2>&1; then
  if sudo firewall-cmd --state >/dev/null 2>&1; then
    sudo firewall-cmd --permanent \
      --add-rich-rule="rule family=\"ipv4\" source address=\"${COLLECTOR_IP}\" port protocol=\"tcp\" port=\"9100\" accept" || true
    sudo firewall-cmd --reload || true
  fi
fi

echo "[INFO] Local test:"
curl -s http://127.0.0.1:9100/metrics | head

echo
echo "[DONE] Node Exporter ready on port 9100."
echo "Next: ask Prometheus admin on ${COLLECTOR_IP} to scrape 10.10.10.21:9100."