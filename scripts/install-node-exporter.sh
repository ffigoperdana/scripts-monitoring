#!/usr/bin/env bash
set -Eeuo pipefail

COLLECTOR_IP="${COLLECTOR_IP:-10.10.10.222}"
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
  [[ "${EUID}" -eq 0 ]] || die "Jalankan script ini sebagai root/sudo."
}

install_node_exporter_debian() {
  export DEBIAN_FRONTEND=noninteractive

  log "Update apt repository..."
  apt-get update

  log "Install prometheus-node-exporter..."
  apt-get install -y curl prometheus-node-exporter
}

configure_service() {
  log "Enable dan restart prometheus-node-exporter..."
  systemctl enable --now prometheus-node-exporter
  systemctl restart prometheus-node-exporter
}

configure_firewall() {
  log "Konfigurasi firewall jika aktif. Allow ${COLLECTOR_IP} ke port ${NODE_PORT}."

  if command -v ufw >/dev/null 2>&1; then
    if ufw status | grep -qi active; then
      ufw allow from "${COLLECTOR_IP}" to any port "${NODE_PORT}" proto tcp || true
      log "UFW rule ditambahkan."
    else
      log "UFW tidak aktif. Skip."
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent \
        --add-rich-rule="rule family=\"ipv4\" source address=\"${COLLECTOR_IP}\" port protocol=\"tcp\" port=\"${NODE_PORT}\" accept" || true
      firewall-cmd --reload || true
      log "firewalld rule ditambahkan."
    else
      log "firewalld tidak aktif. Skip."
    fi
  fi
}

local_test() {
  log "Local test Node Exporter..."

  if curl -fsS "http://127.0.0.1:${NODE_PORT}/metrics" | head; then
    log "OK: Node Exporter hidup di port ${NODE_PORT}."
  else
    die "Node Exporter belum bisa diakses lokal."
  fi
}

main() {
  need_root

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Script ini saat ini dibuat untuk Ubuntu/Debian apt-based."
  fi

  install_node_exporter_debian
  configure_service
  configure_firewall
  local_test

  local local_ip
  local_ip="$(hostname -I | awk '{print $1}')"

  echo
  log "DONE."
  log "VM target siap dipantau."
  log "Local IP kemungkinan: ${local_ip}"
  log "Dari Prometheus server, nanti targetnya: ${local_ip}:${NODE_PORT}"
}

main "$@"