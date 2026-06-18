#!/usr/bin/env bash
set -Eeuo pipefail

MONITOR_IP="${MONITOR_IP:-}"
NODE_PORT="${NODE_PORT:-9100}"

log() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

die() {
  echo "[ERROR] $*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Jalankan sebagai root/sudo."
}

main() {
  need_root

  if [[ -z "${MONITOR_IP}" ]]; then
    die "MONITOR_IP wajib diisi. Contoh: MONITOR_IP=10.10.10.224"
  fi

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Script ini untuk Ubuntu/Debian apt-based."
  fi

  export DEBIAN_FRONTEND=noninteractive

  log "Install Node Exporter..."
  apt-get update
  apt-get install -y curl prometheus-node-exporter

  log "Enable service..."
  systemctl enable --now prometheus-node-exporter
  systemctl restart prometheus-node-exporter

  log "Firewall allow dari monitoring LXC ${MONITOR_IP} ke port ${NODE_PORT}, jika firewall aktif."

  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi active; then
      ufw allow from "${MONITOR_IP}" to any port "${NODE_PORT}" proto tcp || true
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent \
        --add-rich-rule="rule family=\"ipv4\" source address=\"${MONITOR_IP}\" port protocol=\"tcp\" port=\"${NODE_PORT}\" accept" || true
      firewall-cmd --reload || true
    fi
  fi

  log "Local test:"
  curl -fsS "http://127.0.0.1:${NODE_PORT}/metrics" | head

  local local_ip
  local_ip="$(hostname -I | awk '{print $1}')"

  echo
  log "DONE."
  log "Target untuk Prometheus: ${local_ip}:${NODE_PORT}"
}

main "$@"