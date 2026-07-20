#!/usr/bin/env bash
set -Eeuo pipefail

# Based on
# https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/virtualized-platforms/kvm

CLUSTER_NAME="otel-sandbox"

TMP_ROOT="/tmp/.talos-kvm"
CACHE_DIR="${TMP_ROOT}/cache"
CLEANUP_CLUSTER_TMP_DIR="true"

WORKDIR="${TMP_ROOT}/${CLUSTER_NAME}"
CONFIG_DIR="${WORKDIR}/configs"

TALOS_VERSION="v1.13.6"
TALOSCTL_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/talosctl-linux-amd64"
TALOSCTL_SHA256="540c5e7cb0d3fa3a9b2e1c717ced212727b73bcaf0cf9cf9ba2472ec381041d4"

ISO_NAME="metal-amd64-${TALOS_VERSION}.iso"
ISO_PATH="${CACHE_DIR}/${ISO_NAME}"
ISO_URL="https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/metal-amd64.iso"
REGISTRY_ENDPOINT="10.0.0.1:5000"
CONTROL_PLANE_PATCH_FILE="talos/configpatch-controlplane.yaml"
WORKER_PATCH_FILE="talos/configpatch-worker.yaml"

CP_VCPUS="8"
CP_RAM_MB="8192"
WORKER_VCPUS="16"
WORKER_RAM_MB="32768"
DISK_SIZE_GB="40"
INSTALL_DISK="/dev/vda"
OS_VARIANT="linux2022"

CONTROL_PLANE_COUNT=1
WORKER_COUNT=1

DISK_DIR=".state/disks/${CLUSTER_NAME}"
NETWORK_XML="talos/network.xml"
NETWORK_NAME="$(yq '.network.name' "${NETWORK_XML}")"

if ! which talosctl >/dev/null 2>&1; then
  curl --fail --location --retry 3 --output "/tmp/talosctl" "${TALOSCTL_URL}"
  cd /tmp
  echo "${TALOSCTL_SHA256} talosctl" | sha256sum --check --strict
  sudo mv /tmp/talosctl /usr/local/bin/talosctl
  sudo chmod +x /usr/local/bin/talosctl
  cd -
fi

log() { printf '[talos-kvm] %s\n' "$*" >&2; }
die() {
  printf '[talos-kvm] ERROR: %s\n' "$*" >&2
  exit 1
}

cp_name() { printf '%s-control-plane-%s' "${CLUSTER_NAME}" "$1"; }
worker_name() { printf '%s-worker-%s' "${CLUSTER_NAME}" "$1"; }
disk_path() { printf '%s/%s.qcow2' "${DISK_DIR}" "$1"; }

all_vm_names() {
  local i
  for ((i = 1; i <= CONTROL_PLANE_COUNT; i++)); do
    printf '%s\n' "$(cp_name "$i")"
  done

  for ((i = 1; i <= WORKER_COUNT; i++)); do
    printf '%s\n' "$(worker_name "$i")"
  done
}

network_exists() {
  virsh net-info "${NETWORK_NAME}" >/dev/null 2>&1
}

domain_exists() {
  virsh dominfo "$1" >/dev/null 2>&1
}

download_iso() {
  mkdir -p "${CACHE_DIR}"
  if [[ -s "${ISO_PATH}" ]]; then
    log "Using cached Talos ISO: ${ISO_PATH}"
    return
  fi

  log "Downloading Talos ${TALOS_VERSION} ISO"
  local tmp="${ISO_PATH}.partial"
  rm -f "${tmp}"
  curl --fail --location --retry 3 --output "${tmp}" "${ISO_URL}"
  mv "${tmp}" "${ISO_PATH}"
}

create_network() {
  if network_exists; then
    die "Libvirt network ${NETWORK_NAME} already exists; run destroy first"
  fi

  log "Defining libvirt network ${NETWORK_NAME}"
  virsh net-define "${NETWORK_XML}" >/dev/null
  virsh net-start "${NETWORK_NAME}" >/dev/null
  virsh net-autostart "${NETWORK_NAME}" >/dev/null
}

create_vm() {
  local name="$1" ram_mb="$2" vcpus="$3"
  local disk
  disk="$(disk_path "${name}")"

  domain_exists "${name}" && die "Libvirt domain ${name} already exists; run destroy first"
  [[ ! -e "${disk}" ]] || die "Disk already exists: ${disk}; run destroy first"

  log "Creating VM ${name} (${vcpus} vCPU, ${ram_mb} MiB RAM, ${DISK_SIZE_GB} GiB disk)"
  virt-install \
    --virt-type kvm \
    --name "${name}" \
    --memory "${ram_mb}" \
    --vcpus "${vcpus}" \
    --disk "path=${disk},bus=virtio,size=${DISK_SIZE_GB},format=qcow2" \
    --cdrom "${ISO_PATH}" \
    --os-variant "${OS_VARIANT}" \
    --network "network=${NETWORK_NAME},model=virtio" \
    --boot "hd,cdrom" \
    --graphics none \
    --noautoconsole \
    --wait 0 >/dev/null
}

get_domain_ip() {
  local name="$1"
  virsh domifaddr "${name}" --source lease 2>/dev/null |
    awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

wait_for_ip() {
  local name="$1" timeout="${2:-180}"
  local started now ip
  started="$(date +%s)"

  log "Waiting for DHCP address for ${name}"
  while true; do
    ip="$(get_domain_ip "${name}" || true)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return
    fi

    now="$(date +%s)"
    ((now - started < timeout)) || die "Timed out waiting for an IP address for ${name}"
    sleep 2
  done
}

wait_for_talos_insecure() {
  local ip="$1" timeout="${2:-180}"
  local started now
  started="$(date +%s)"
  log "Waiting for Talos maintenance API on ${ip}"

  until talosctl get disks --nodes "${ip}" --insecure >/dev/null 2>&1; do
    now="$(date +%s)"
    ((now - started < timeout)) || die "Timed out waiting for Talos maintenance API on ${ip}"
    sleep 3
  done
}

wait_for_talos_api() {
  local talosconfig_path="$1" ip="$2" timeout="${3:-300}"
  local started now
  started="$(date +%s)"
  log "Waiting for configured Talos API on ${ip}"

  until talosctl --talosconfig "${talosconfig_path}" --context "${CLUSTER_NAME}" --nodes "${ip}" version; do
    now="$(date +%s)"
    ((now - started < timeout)) || die "Timed out waiting for configured Talos API on ${ip}"
    sleep 3
  done
}

cleanup_cluster_tmp_dir() {
  [[ "${CLEANUP_CLUSTER_TMP_DIR}" == "true" ]] || return 0

  log "Removing temporary cluster runtime state in ${WORKDIR}"
  rm -rf -- "${WORKDIR}"
}

create_cluster() {
  mkdir -p "${CONFIG_DIR}" "${DISK_DIR}"

  local name
  while IFS= read -r name; do
    domain_exists "${name}" && die "Domain ${name} already exists; run destroy first"
  done < <(all_vm_names)
  network_exists && die "Network ${NETWORK_NAME} already exists; run destroy first"

  download_iso
  create_network

  local i
  for ((i = 1; i <= CONTROL_PLANE_COUNT; i++)); do
    create_vm "$(cp_name "$i")" "${CP_RAM_MB}" "${CP_VCPUS}"
  done
  for ((i = 1; i <= WORKER_COUNT; i++)); do
    create_vm "$(worker_name "$i")" "${WORKER_RAM_MB}" "${WORKER_VCPUS}"
  done

  local -a cp_ips=() worker_ips=()
  for ((i = 1; i <= CONTROL_PLANE_COUNT; i++)); do
    cp_ips+=("$(wait_for_ip "$(cp_name "$i")")")
  done
  for ((i = 1; i <= WORKER_COUNT; i++)); do
    worker_ips+=("$(wait_for_ip "$(worker_name "$i")")")
  done

  local bootstrap_ip="${cp_ips[0]}"
  wait_for_talos_insecure "${bootstrap_ip}"

  rm -rf "${CONFIG_DIR}"
  mkdir -p "${CONFIG_DIR}"

  log "Generating Talos machine configuration"
  talosctl gen config \
    "${CLUSTER_NAME}" \
    "https://${bootstrap_ip}:6443" \
    --install-disk "${INSTALL_DISK}" \
    --registry-mirror "${REGISTRY_ENDPOINT}=http://${REGISTRY_ENDPOINT}" \
    --config-patch-control-plane "@${CONTROL_PLANE_PATCH_FILE}" \
    --config-patch-worker "@${WORKER_PATCH_FILE}" \
    --output-dir "${CONFIG_DIR}"

  log "Applying control-plane configurations"
  local ip
  for ip in "${cp_ips[@]}"; do
    talosctl apply-config --insecure --nodes "${ip}" --file "${CONFIG_DIR}/controlplane.yaml"
  done

  if ((WORKER_COUNT > 0)); then
    log "Applying worker configurations"
    for ip in "${worker_ips[@]}"; do
      talosctl apply-config --insecure --nodes "${ip}" --file "${CONFIG_DIR}/worker.yaml"
    done
  fi

  local cluster_talosconfig="${CONFIG_DIR}/talosconfig"
  talosctl --talosconfig "${cluster_talosconfig}" config endpoint "${cp_ips[@]}" >/dev/null
  talosctl --talosconfig "${cluster_talosconfig}" config node "${bootstrap_ip}" >/dev/null

  wait_for_talos_api "${cluster_talosconfig}" "${bootstrap_ip}"

  log "Bootstrapping Kubernetes"
  talosctl --talosconfig "${cluster_talosconfig}" --context "${CLUSTER_NAME}" --nodes "${bootstrap_ip}" bootstrap

  log "Waiting for bootstrap to settle"
  talosctl --talosconfig "${cluster_talosconfig}" --context "${CLUSTER_NAME}" --nodes "${bootstrap_ip}" health --wait-timeout 10m

  log "Merging kubeconfig into default kubeconfig"
  talosctl --talosconfig "${cluster_talosconfig}" --context "${CLUSTER_NAME}" --nodes "${bootstrap_ip}" kubeconfig --force --force-context-name "${CLUSTER_NAME}"

  log "Refreshing Talos context in default talosconfig"
  if [[ -f "${HOME}/.talos/config" ]]; then
    yq -i "del(.contexts.\"${CLUSTER_NAME}\")" "${HOME}/.talos/config"
  fi
  talosctl config merge "${cluster_talosconfig}" >/dev/null
  talosctl config context "${CLUSTER_NAME}" >/dev/null
  talosctl config endpoint "${cp_ips[@]}" >/dev/null
  talosctl config node "${bootstrap_ip}" >/dev/null

  cleanup_cluster_tmp_dir

  log "Cluster created successfully"
  kubectl --context "${CLUSTER_NAME}" get nodes -o wide
}

destroy_domain() {
  local name="$1"
  if ! domain_exists "${name}"; then
    return
  fi

  log "Removing VM ${name}"
  virsh destroy "${name}" >/dev/null 2>&1 || true
  virsh undefine "${name}" --remove-all-storage --nvram >/dev/null 2>&1 ||
    virsh undefine "${name}" --remove-all-storage >/dev/null 2>&1 ||
    virsh undefine "${name}" >/dev/null 2>&1 ||
    true
}

destroy_cluster() {
  local name

  while IFS= read -r name; do
    destroy_domain "${name}"
    rm -f -- "$(disk_path "${name}")"
  done < <(all_vm_names)

  if network_exists; then
    log "Removing libvirt network ${NETWORK_NAME}"
    virsh net-destroy "${NETWORK_NAME}" >/dev/null 2>&1 || true
    virsh net-undefine "${NETWORK_NAME}" >/dev/null 2>&1 || true
  fi

  talosctl config remove "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-context "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-cluster "${CLUSTER_NAME}" >/dev/null 2>&1 || true
  kubectl config delete-user "admin@${CLUSTER_NAME}" >/dev/null 2>&1 || true

  cleanup_cluster_tmp_dir

  rm -rf "${DISK_DIR}"
}

show_status() {
  printf 'Cluster: %s\nWorkdir: %s\nNetwork: %s\n\n' "${CLUSTER_NAME}" "${WORKDIR}" "${NETWORK_NAME}"

  if network_exists; then
    virsh net-info "${NETWORK_NAME}"
  else
    printf 'Network does not exist.\n'
  fi

  printf '\nVMs:\n'
  local name
  while IFS= read -r name; do
    if domain_exists "${name}"; then
      printf '%-40s state=%-12s ip=%s\n' \
        "${name}" \
        "$(virsh domstate "${name}" 2>/dev/null | tr -d '\r')" \
        "$(get_domain_ip "${name}" || true)"
    else
      printf '%-40s absent\n' "${name}"
    fi
  done < <(all_vm_names)

  if kubectl config get-contexts "${CLUSTER_NAME}" >/dev/null 2>&1; then
    printf '\nKubernetes nodes:\n'
    kubectl --context "${CLUSTER_NAME}" get nodes -o wide || true
  fi
}

main() {
  case "${1:-}" in
  "")
    create_cluster
    ;;
  create) create_cluster ;;
  destroy) destroy_cluster ;;
  status) show_status ;;
  *)
    die "Unknown command: $1"
    ;;
  esac
}

main "$@"
