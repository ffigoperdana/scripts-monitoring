#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_GROUP="${TARGET_GROUP:-internal-vm-network}"
NODE_JOB="${NODE_JOB:-internal_vm_network_node}"
ICMP_JOB="${ICMP_JOB:-internal_vm_network_icmp}"
TCP_JOB="${TCP_JOB:-internal_vm_network_tcp}"

FILE_SD_DIR="${FILE_SD_DIR:-/etc/prometheus/file_sd/internal-vm-network}"
PROM_FILE="${PROM_FILE:-/etc/prometheus/prometheus.yml}"
BLACKBOX_CONFIG="${BLACKBOX_CONFIG:-/etc/prometheus/blackbox.yml}"

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

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  log "Install Prometheus, Blackbox Exporter, Node Exporter..."
  apt-get update
  apt-get install -y \
    curl \
    python3 \
    python3-yaml \
    libcap2-bin \
    prometheus \
    prometheus-blackbox-exporter \
    prometheus-node-exporter
}

configure_blackbox() {
  log "Konfigurasi Blackbox Exporter..."

  mkdir -p /etc/prometheus

  if [[ -f "${BLACKBOX_CONFIG}" ]]; then
    cp -a "${BLACKBOX_CONFIG}" "${BLACKBOX_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat >"${BLACKBOX_CONFIG}" <<'EOF'
modules:
  icmp:
    prober: icmp
    timeout: 5s
    icmp:
      preferred_ip_protocol: ip4

  tcp_connect:
    prober: tcp
    timeout: 5s
    tcp:
      preferred_ip_protocol: ip4

  http_2xx:
    prober: http
    timeout: 10s
    http:
      preferred_ip_protocol: ip4
      valid_status_codes: []
      method: GET
EOF

  log "Enable permission ICMP untuk Blackbox."

  cat >/etc/sysctl.d/99-blackbox-icmp.conf <<'EOF'
net.ipv4.ping_group_range = 0 2147483647
EOF

  sysctl --system >/dev/null || warn "sysctl gagal diterapkan."

  local bb_bin=""
  bb_bin="$(command -v prometheus-blackbox-exporter || true)"

  if [[ -z "${bb_bin}" ]]; then
    bb_bin="$(command -v blackbox_exporter || true)"
  fi

  if [[ -n "${bb_bin}" ]]; then
    setcap cap_net_raw+ep "${bb_bin}" || warn "setcap gagal. ICMP mungkin gagal di LXC unprivileged."
  else
    warn "Binary blackbox exporter tidak ditemukan untuk setcap."
  fi

  mkdir -p /etc/systemd/system/prometheus-blackbox-exporter.service.d

  cat >/etc/systemd/system/prometheus-blackbox-exporter.service.d/override.conf <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=false
EOF
}

init_file_sd() {
  log "Inisialisasi file_sd target..."

  mkdir -p "${FILE_SD_DIR}"

  cat >"${FILE_SD_DIR}/node_targets.yml" <<EOF
- targets:
    - "127.0.0.1:9100"
  labels:
    name: "mon-prom-01"
    role: "monitoring"
    group: "${TARGET_GROUP}"
EOF

  cat >"${FILE_SD_DIR}/icmp_targets.yml" <<EOF
- targets:
    - "127.0.0.1"
  labels:
    name: "mon-prom-01"
    role: "monitoring"
    group: "${TARGET_GROUP}"
EOF

  cat >"${FILE_SD_DIR}/tcp_targets.yml" <<EOF
- targets:
    - "127.0.0.1:9090"
    - "127.0.0.1:9115"
  labels:
    name: "mon-prom-01"
    role: "monitoring"
    group: "${TARGET_GROUP}"
EOF

  if id prometheus >/dev/null 2>&1; then
    chown -R prometheus:prometheus "${FILE_SD_DIR}" || true
  fi
}

configure_prometheus() {
  log "Konfigurasi Prometheus..."

  if [[ -f "${PROM_FILE}" ]]; then
    cp -a "${PROM_FILE}" "${PROM_FILE}.bak.$(date +%Y%m%d%H%M%S)"
  fi

  cat >"${PROM_FILE}" <<EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: prometheus_self
    static_configs:
      - targets:
          - 127.0.0.1:9090
        labels:
          name: mon-prom-01
          role: monitoring
          group: ${TARGET_GROUP}

  - job_name: ${NODE_JOB}
    file_sd_configs:
      - files:
          - ${FILE_SD_DIR}/node_targets.yml
        refresh_interval: 30s

  - job_name: ${ICMP_JOB}
    metrics_path: /probe
    params:
      module:
        - icmp
    file_sd_configs:
      - files:
          - ${FILE_SD_DIR}/icmp_targets.yml
        refresh_interval: 30s
    relabel_configs:
      - source_labels:
          - __address__
        target_label: __param_target
      - source_labels:
          - __param_target
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115

  - job_name: ${TCP_JOB}
    metrics_path: /probe
    params:
      module:
        - tcp_connect
    file_sd_configs:
      - files:
          - ${FILE_SD_DIR}/tcp_targets.yml
        refresh_interval: 30s
    relabel_configs:
      - source_labels:
          - __address__
        target_label: __param_target
      - source_labels:
          - __param_target
        target_label: instance
      - target_label: __address__
        replacement: 127.0.0.1:9115
EOF

  if command -v promtool >/dev/null 2>&1; then
    promtool check config "${PROM_FILE}"
  fi
}

create_add_target_tool() {
  log "Membuat helper /usr/local/bin/add-internal-vm-target..."

  cat >/usr/local/bin/add-internal-vm-target <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_IP="${TARGET_IP:-}"
TARGET_NAME="${TARGET_NAME:-}"
TARGET_ROLE="${TARGET_ROLE:-vm}"
TARGET_GROUP="${TARGET_GROUP:-internal-vm-network}"

NODE_EXPORTER="${NODE_EXPORTER:-true}"
NODE_PORT="${NODE_PORT:-9100}"
TCP_PORTS="${TCP_PORTS:-22}"

PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
FILE_SD_DIR="${FILE_SD_DIR:-/etc/prometheus/file_sd/internal-vm-network}"

NODE_JOB="${NODE_JOB:-internal_vm_network_node}"
ICMP_JOB="${ICMP_JOB:-internal_vm_network_icmp}"
TCP_JOB="${TCP_JOB:-internal_vm_network_tcp}"

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

[[ -n "${TARGET_IP}" ]] || die "TARGET_IP wajib. Contoh: TARGET_IP=10.10.10.21"
[[ -n "${TARGET_NAME}" ]] || TARGET_NAME="${TARGET_IP}"

upsert_yaml() {
  local file="$1"
  local target="$2"
  local name="$3"
  local role="$4"
  local group="$5"

  mkdir -p "$(dirname "${file}")"

  python3 - "${file}" "${target}" "${name}" "${role}" "${group}" <<'PY'
import os
import sys
import yaml

path, target, name, role, group = sys.argv[1:]

try:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or []
except Exception:
    data = []

result = []

for item in data:
    targets = item.get("targets", [])
    if target not in targets:
        result.append(item)

result.append({
    "targets": [target],
    "labels": {
        "name": name,
        "role": role,
        "group": group,
    }
})

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    yaml.safe_dump(result, f, sort_keys=False)

os.replace(tmp, path)
PY
}

log "Add target:"
log "  IP        : ${TARGET_IP}"
log "  Name      : ${TARGET_NAME}"
log "  Role      : ${TARGET_ROLE}"
log "  Group     : ${TARGET_GROUP}"
log "  Node      : ${NODE_EXPORTER}"
log "  TCP ports : ${TCP_PORTS}"

if [[ "${NODE_EXPORTER}" == "true" ]]; then
  upsert_yaml \
    "${FILE_SD_DIR}/node_targets.yml" \
    "${TARGET_IP}:${NODE_PORT}" \
    "${TARGET_NAME}" \
    "${TARGET_ROLE}" \
    "${TARGET_GROUP}"
fi

upsert_yaml \
  "${FILE_SD_DIR}/icmp_targets.yml" \
  "${TARGET_IP}" \
  "${TARGET_NAME}" \
  "${TARGET_ROLE}" \
  "${TARGET_GROUP}"

if [[ -n "${TCP_PORTS}" ]]; then
  for port in ${TCP_PORTS}; do
    upsert_yaml \
      "${FILE_SD_DIR}/tcp_targets.yml" \
      "${TARGET_IP}:${port}" \
      "${TARGET_NAME}" \
      "${TARGET_ROLE}" \
      "${TARGET_GROUP}"
  done
fi

if id prometheus >/dev/null 2>&1; then
  chown -R prometheus:prometheus "${FILE_SD_DIR}" || true
fi

log "Menunggu Prometheus file_sd refresh..."
sleep 35

echo
log "Check ICMP:"
curl -fsS -G "${PROM_URL}/api/v1/query" \
  --data-urlencode "query=probe_success{job=\"${ICMP_JOB}\",instance=\"${TARGET_IP}\"}" || true
echo

if [[ "${NODE_EXPORTER}" == "true" ]]; then
  echo
  log "Check Node Exporter:"
  curl -fsS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=up{job=\"${NODE_JOB}\",instance=\"${TARGET_IP}:${NODE_PORT}\"}" || true
  echo
fi

if [[ -n "${TCP_PORTS}" ]]; then
  for port in ${TCP_PORTS}; do
    echo
    log "Check TCP ${port}:"
    curl -fsS -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=probe_success{job=\"${TCP_JOB}\",instance=\"${TARGET_IP}:${port}\"}" || true
    echo
  done
fi

log "DONE."
EOF

  chmod +x /usr/local/bin/add-internal-vm-target
}

restart_services() {
  log "Restart services..."

  systemctl daemon-reload

  systemctl enable --now prometheus-node-exporter
  systemctl enable --now prometheus-blackbox-exporter
  systemctl enable --now prometheus

  systemctl restart prometheus-node-exporter
  systemctl restart prometheus-blackbox-exporter
  systemctl restart prometheus
}

test_services() {
  log "Test Prometheus..."
  curl -fsS http://127.0.0.1:9090/-/ready
  echo

  log "Test Blackbox metrics..."
  curl -fsS http://127.0.0.1:9115/metrics | head
  echo

  log "Test ICMP probe localhost..."
  curl -fsS "http://127.0.0.1:9115/probe?target=127.0.0.1&module=icmp" | grep probe_success || true
  echo
}

main() {
  need_root

  if ! command -v apt-get >/dev/null 2>&1; then
    die "Script ini untuk Debian/Ubuntu apt-based LXC."
  fi

  install_packages
  configure_blackbox
  init_file_sd
  configure_prometheus
  create_add_target_tool
  restart_services
  test_services

  local ip_addr
  ip_addr="$(hostname -I | awk '{print $1}')"

  echo
  log "DONE."
  log "Prometheus URL : http://${ip_addr}:9090"
  log "Blackbox URL   : http://${ip_addr}:9115"
  log "Grafana nanti add datasource ke: http://${ip_addr}:9090"
}

main "$@"