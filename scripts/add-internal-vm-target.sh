#!/usr/bin/env bash
set -Eeuo pipefail

# Add a new VM/device target into Prometheus file_sd for the
# Internal VM Network monitoring stack.
# Run this script on the Prometheus LXC, e.g. mon-prom-1 / 10.10.10.224.
#
# Example:
#   TARGET_IP=10.10.10.21 \
#   TARGET_NAME=sysmon \
#   TARGET_ROLE=system-monitoring \
#   NODE_EXPORTER=true \
#   TCP_PORTS="22" \
#   bash add-internal-vm-target.sh

TARGET_IP="${TARGET_IP:-}"
TARGET_NAME="${TARGET_NAME:-}"
TARGET_ROLE="${TARGET_ROLE:-vm}"
TARGET_GROUP="${TARGET_GROUP:-internal-vm-network}"

NODE_EXPORTER="${NODE_EXPORTER:-true}"
NODE_PORT="${NODE_PORT:-9100}"
TCP_PORTS="${TCP_PORTS:-22}"

FILE_SD_DIR="${FILE_SD_DIR:-/etc/prometheus/file_sd/internal-vm-network}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"

NODE_JOB="${NODE_JOB:-internal_vm_network_node}"
ICMP_JOB="${ICMP_JOB:-internal_vm_network_icmp}"
TCP_JOB="${TCP_JOB:-internal_vm_network_tcp}"

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Jalankan script ini sebagai root/sudo di server Prometheus LXC."
}

validate_input() {
  [[ -n "${TARGET_IP}" ]] || die "TARGET_IP wajib diisi. Contoh: TARGET_IP=10.10.10.21"
  [[ -n "${TARGET_NAME}" ]] || TARGET_NAME="${TARGET_IP}"

  if [[ ! "${TARGET_IP}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    warn "TARGET_IP tidak terlihat seperti IPv4 standar: ${TARGET_IP}"
  fi

  case "${NODE_EXPORTER}" in
    true|false) ;;
    *) die "NODE_EXPORTER harus true atau false." ;;
  esac
}

install_deps_if_needed() {
  if ! command -v python3 >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y python3
    else
      die "python3 belum tersedia. Install python3 dulu."
    fi
  fi

  python3 - <<'PY' >/dev/null 2>&1 || NEED_YAML=true
import yaml
PY

  if [[ "${NEED_YAML:-false}" == "true" ]]; then
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y python3-yaml
    else
      die "Module PyYAML belum tersedia. Install python3-yaml/PyYAML dulu."
    fi
  fi

  command -v curl >/dev/null 2>&1 || {
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update
      apt-get install -y curl
    else
      die "curl belum tersedia."
    fi
  }
}

backup_file_sd() {
  mkdir -p "${FILE_SD_DIR}"
  local ts
  ts="$(date +%Y%m%d%H%M%S)"
  for file in node_targets.yml icmp_targets.yml tcp_targets.yml; do
    if [[ -f "${FILE_SD_DIR}/${file}" ]]; then
      cp -a "${FILE_SD_DIR}/${file}" "${FILE_SD_DIR}/${file}.bak.${ts}"
    fi
  done
}

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
except FileNotFoundError:
    data = []
except Exception as exc:
    raise SystemExit(f"Failed to read YAML {path}: {exc}")

if not isinstance(data, list):
    raise SystemExit(f"YAML {path} must be a list of file_sd target groups")

result = []
for item in data:
    if not isinstance(item, dict):
        continue
    targets = item.get("targets", []) or []
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

add_targets() {
  log "Menambahkan target ke Prometheus file_sd"
  log "Target IP      : ${TARGET_IP}"
  log "Target name    : ${TARGET_NAME}"
  log "Target role    : ${TARGET_ROLE}"
  log "Target group   : ${TARGET_GROUP}"
  log "Node exporter  : ${NODE_EXPORTER}"
  log "TCP ports      : ${TCP_PORTS:-none}"
  log "file_sd dir    : ${FILE_SD_DIR}"

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
}

precheck_reachability() {
  log "Precheck reachability dari Prometheus LXC"

  if command -v ping >/dev/null 2>&1; then
    if ping -c 2 -W 2 "${TARGET_IP}" >/dev/null 2>&1; then
      log "OK: ICMP ping ke ${TARGET_IP} sukses."
    else
      warn "ICMP ping ke ${TARGET_IP} gagal. Target tetap ditambahkan; alert ICMP mungkin langsung firing."
    fi
  fi

  if [[ "${NODE_EXPORTER}" == "true" ]]; then
    if curl -fsS --max-time 5 "http://${TARGET_IP}:${NODE_PORT}/metrics" >/dev/null 2>&1; then
      log "OK: Node Exporter reachable di ${TARGET_IP}:${NODE_PORT}."
    else
      warn "Node Exporter belum reachable di ${TARGET_IP}:${NODE_PORT}. Cek install-node-exporter.sh/firewall."
    fi
  fi
}

postcheck_prometheus() {
  log "Menunggu Prometheus file_sd refresh sekitar 35 detik..."
  sleep 35

  echo
  log "Check ICMP metric:"
  curl -fsS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=probe_success{job=\"${ICMP_JOB}\",instance=\"${TARGET_IP}\"}" || true
  echo

  if [[ "${NODE_EXPORTER}" == "true" ]]; then
    echo
    log "Check Node Exporter metric:"
    curl -fsS -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=up{job=\"${NODE_JOB}\",instance=\"${TARGET_IP}:${NODE_PORT}\"}" || true
    echo
  fi

  if [[ -n "${TCP_PORTS}" ]]; then
    for port in ${TCP_PORTS}; do
      echo
      log "Check TCP ${port} metric:"
      curl -fsS -G "${PROM_URL}/api/v1/query" \
        --data-urlencode "query=probe_success{job=\"${TCP_JOB}\",instance=\"${TARGET_IP}:${port}\"}" || true
      echo
    done
  fi
}

main() {
  need_root
  validate_input
  install_deps_if_needed
  backup_file_sd
  precheck_reachability
  add_targets
  postcheck_prometheus

  echo
  log "DONE. Target sudah ditambahkan."
  log "Cek Prometheus Targets: ${PROM_URL}/targets"
  log "Query Grafana/Prometheus: up{group=\"${TARGET_GROUP}\"}"
}

main "$@"
