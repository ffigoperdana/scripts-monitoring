#!/usr/bin/env bash
set -Eeuo pipefail

TARGET_IP="${TARGET_IP:-}"
TARGET_NAME="${TARGET_NAME:-}"
TARGET_ROLE="${TARGET_ROLE:-vm}"
TARGET_GROUP="${TARGET_GROUP:-internal-vm-network}"

NODE_PORT="${NODE_PORT:-9100}"
TCP_PORTS="${TCP_PORTS:-22}"

PROM_FILE="${PROM_FILE:-}"
PROM_URL="${PROM_URL:-http://127.0.0.1:9090}"
FILE_SD_DIR="${FILE_SD_DIR:-/etc/prometheus/file_sd/internal-vm-network}"

BLACKBOX_ADDRESS="${BLACKBOX_ADDRESS:-127.0.0.1:9115}"

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

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Jalankan script ini sebagai root/sudo."
}

need_target() {
  [[ -n "${TARGET_IP}" ]] || die "TARGET_IP wajib diisi. Contoh: TARGET_IP=10.10.10.21"

  if [[ -z "${TARGET_NAME}" ]]; then
    TARGET_NAME="${TARGET_IP}"
  fi
}

install_deps() {
  log "Cek dependency..."

  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl python3 python3-yaml
  else
    command -v curl >/dev/null 2>&1 || die "curl belum tersedia."
    command -v python3 >/dev/null 2>&1 || die "python3 belum tersedia."

    python3 - <<'PY' >/dev/null 2>&1 || exit 1
import yaml
PY

    if [[ "$?" -ne 0 ]]; then
      die "Module PyYAML belum tersedia. Install python3-yaml / PyYAML dulu."
    fi
  fi
}

detect_prom_file() {
  if [[ -n "${PROM_FILE}" && -f "${PROM_FILE}" ]]; then
    echo "${PROM_FILE}"
    return
  fi

  local candidates=(
    "/etc/prometheus/prometheus.yml"
    "/etc/prometheus/prometheus.yaml"
    "/opt/prometheus/prometheus.yml"
    "/opt/prometheus/prometheus.yaml"
    "/usr/local/prometheus/prometheus.yml"
    "/usr/local/prometheus/prometheus.yaml"
  )

  for file in "${candidates[@]}"; do
    if [[ -f "${file}" ]]; then
      echo "${file}"
      return
    fi
  done

  local found
  found="$(find /etc /opt /usr/local -maxdepth 5 -type f \( -name "prometheus.yml" -o -name "prometheus.yaml" \) 2>/dev/null | head -n 1 || true)"

  if [[ -n "${found}" ]]; then
    echo "${found}"
    return
  fi

  die "File prometheus.yml tidak ditemukan. Jalankan ulang dengan PROM_FILE=/path/to/prometheus.yml"
}

upsert_file_sd_yaml() {
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

write_file_sd_targets() {
  log "Menulis target ke file_sd: ${FILE_SD_DIR}"

  mkdir -p "${FILE_SD_DIR}"

  upsert_file_sd_yaml \
    "${FILE_SD_DIR}/node_targets.yml" \
    "${TARGET_IP}:${NODE_PORT}" \
    "${TARGET_NAME}" \
    "${TARGET_ROLE}" \
    "${TARGET_GROUP}"

  upsert_file_sd_yaml \
    "${FILE_SD_DIR}/icmp_targets.yml" \
    "${TARGET_IP}" \
    "${TARGET_NAME}" \
    "${TARGET_ROLE}" \
    "${TARGET_GROUP}"

  for port in ${TCP_PORTS}; do
    upsert_file_sd_yaml \
      "${FILE_SD_DIR}/tcp_targets.yml" \
      "${TARGET_IP}:${port}" \
      "${TARGET_NAME}" \
      "${TARGET_ROLE}" \
      "${TARGET_GROUP}"
  done

  if id prometheus >/dev/null 2>&1; then
    chown -R prometheus:prometheus "${FILE_SD_DIR}" || true
  fi
}

patch_prometheus_config() {
  local prom_file="$1"

  log "Backup Prometheus config..."
  cp -a "${prom_file}" "${prom_file}.bak.$(date +%Y%m%d%H%M%S)"

  log "Patch scrape_configs di ${prom_file}..."

  python3 - "${prom_file}" "${FILE_SD_DIR}" "${BLACKBOX_ADDRESS}" "${NODE_JOB}" "${ICMP_JOB}" "${TCP_JOB}" <<'PY'
import sys
import yaml

prom_file, file_sd_dir, blackbox_address, node_job, icmp_job, tcp_job = sys.argv[1:]

with open(prom_file, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("global", {})
cfg["global"].setdefault("scrape_interval", "15s")
cfg["global"].setdefault("evaluation_interval", "15s")
cfg.setdefault("scrape_configs", [])

def upsert_job(job):
    jobs = cfg["scrape_configs"]
    name = job["job_name"]

    for index, existing in enumerate(jobs):
        if existing.get("job_name") == name:
            jobs[index] = job
            return

    jobs.append(job)

upsert_job({
    "job_name": node_job,
    "file_sd_configs": [
        {
            "files": [
                f"{file_sd_dir}/node_targets.yml",
            ],
            "refresh_interval": "30s",
        }
    ],
})

blackbox_relabel_configs = [
    {
        "source_labels": ["__address__"],
        "target_label": "__param_target",
    },
    {
        "source_labels": ["__param_target"],
        "target_label": "instance",
    },
    {
        "target_label": "__address__",
        "replacement": blackbox_address,
    },
]

upsert_job({
    "job_name": icmp_job,
    "metrics_path": "/probe",
    "params": {
        "module": ["icmp"],
    },
    "file_sd_configs": [
        {
            "files": [
                f"{file_sd_dir}/icmp_targets.yml",
            ],
            "refresh_interval": "30s",
        }
    ],
    "relabel_configs": blackbox_relabel_configs,
})

upsert_job({
    "job_name": tcp_job,
    "metrics_path": "/probe",
    "params": {
        "module": ["tcp_connect"],
    },
    "file_sd_configs": [
        {
            "files": [
                f"{file_sd_dir}/tcp_targets.yml",
            ],
            "refresh_interval": "30s",
        }
    ],
    "relabel_configs": blackbox_relabel_configs,
})

with open(prom_file, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)
PY
}

validate_prometheus_config() {
  local prom_file="$1"

  if command -v promtool >/dev/null 2>&1; then
    log "Validasi config dengan promtool..."
    promtool check config "${prom_file}"
  else
    warn "promtool tidak ditemukan. Skip validasi."
  fi
}

reload_prometheus() {
  log "Reload/restart Prometheus..."

  local ok="false"

  if systemctl is-active --quiet prometheus 2>/dev/null; then
    systemctl reload prometheus && ok="true" || true

    if [[ "${ok}" != "true" ]]; then
      systemctl restart prometheus && ok="true" || true
    fi
  fi

  if systemctl is-active --quiet prometheus-server 2>/dev/null; then
    systemctl reload prometheus-server && ok="true" || true

    if [[ "${ok}" != "true" ]]; then
      systemctl restart prometheus-server && ok="true" || true
    fi
  fi

  if [[ "${ok}" != "true" ]]; then
    if curl -fsS -X POST "${PROM_URL}/-/reload" >/dev/null 2>&1; then
      ok="true"
    fi
  fi

  if [[ "${ok}" != "true" ]]; then
    warn "Reload otomatis belum berhasil."
    warn "Kalau Prometheus jalan via Docker, restart container Prometheus manual."
    warn "Contoh: docker restart prometheus"
  fi
}

precheck() {
  log "Precheck dari server ini ke target."

  if curl -fsS --max-time 5 "http://${TARGET_IP}:${NODE_PORT}/metrics" >/dev/null; then
    log "OK: Node Exporter reachable di ${TARGET_IP}:${NODE_PORT}"
  else
    warn "Belum bisa akses Node Exporter di ${TARGET_IP}:${NODE_PORT}"
    warn "Cek apakah install-node-exporter.sh sudah jalan dan firewall target allow dari server ini."
  fi

  if curl -fsS --max-time 5 "http://${BLACKBOX_ADDRESS}/metrics" >/dev/null; then
    log "OK: Blackbox Exporter reachable di ${BLACKBOX_ADDRESS}"
  else
    warn "Blackbox Exporter belum reachable di ${BLACKBOX_ADDRESS}"
    warn "Kalau Blackbox bukan di localhost, jalankan dengan BLACKBOX_ADDRESS=IP:9115"
  fi
}

postcheck() {
  log "Menunggu Prometheus refresh..."
  sleep 10

  echo
  log "Query cek Node Exporter:"
  echo "up{job=\"${NODE_JOB}\",instance=\"${TARGET_IP}:${NODE_PORT}\"}"
  curl -fsS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=up{job=\"${NODE_JOB}\",instance=\"${TARGET_IP}:${NODE_PORT}\"}" || true

  echo
  echo
  log "Query cek ICMP:"
  echo "probe_success{job=\"${ICMP_JOB}\",instance=\"${TARGET_IP}\"}"
  curl -fsS -G "${PROM_URL}/api/v1/query" \
    --data-urlencode "query=probe_success{job=\"${ICMP_JOB}\",instance=\"${TARGET_IP}\"}" || true

  echo
  echo
  log "Query cek TCP:"
  for port in ${TCP_PORTS}; do
    echo "probe_success{job=\"${TCP_JOB}\",instance=\"${TARGET_IP}:${port}\"}"
    curl -fsS -G "${PROM_URL}/api/v1/query" \
      --data-urlencode "query=probe_success{job=\"${TCP_JOB}\",instance=\"${TARGET_IP}:${port}\"}" || true
    echo
  done
}

main() {
  need_root
  need_target
  install_deps

  local prom_file
  prom_file="$(detect_prom_file)"

  log "Add VM to Prometheus"
  log "Prometheus config : ${prom_file}"
  log "Prometheus URL    : ${PROM_URL}"
  log "Target IP         : ${TARGET_IP}"
  log "Target name       : ${TARGET_NAME}"
  log "Target role       : ${TARGET_ROLE}"
  log "Target group      : ${TARGET_GROUP}"
  log "Node port         : ${NODE_PORT}"
  log "TCP ports         : ${TCP_PORTS}"
  log "Blackbox address  : ${BLACKBOX_ADDRESS}"

  precheck
  write_file_sd_targets
  patch_prometheus_config "${prom_file}"
  validate_prometheus_config "${prom_file}"
  reload_prometheus
  postcheck

  echo
  log "DONE."
  log "Cek di Grafana Explore:"
  log "  up{job=\"${NODE_JOB}\",instance=\"${TARGET_IP}:${NODE_PORT}\"}"
  log "  probe_success{job=\"${ICMP_JOB}\",instance=\"${TARGET_IP}\"}"
  log "  probe_success{job=\"${TCP_JOB}\",instance=\"${TARGET_IP}:22\"}"
  log "  up{group=\"${TARGET_GROUP}\"}"
}

main "$@"