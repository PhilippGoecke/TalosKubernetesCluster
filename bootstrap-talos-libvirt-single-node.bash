#!/usr/bin/env bash
# Bootstrap a single-node Talos Kubernetes cluster on a libvirt host.
#
# Prerequisites on the *Linux libvirt host*:
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CREATE_SCRIPT="${SCRIPT_DIR}/create-single-node.bash"
readonly LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"

CLUSTER_NAME="${CLUSTER_NAME:-singlenode-virtcluster}"
TALOS_VERSION="${TALOS_VERSION:-v1.13.3}"
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.36.1}"
NODE_IP="${NODE_IP:-}"
INSTALL_DISK="${INSTALL_DISK:-}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-}"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

bootstrap_libvirt() {
  local network_info start_error

  network_info="$(virsh --connect qemu:///system net-info "${LIBVIRT_NETWORK}")" ||
    die "Libvirt network does not exist or is inaccessible: ${LIBVIRT_NETWORK}"

  if ! grep -Eq '^[[:space:]]*Active:[[:space:]]*yes[[:space:]]*$' <<<"${network_info}"; then
    log "Starting libvirt network: ${LIBVIRT_NETWORK}"
    if ! start_error="$(virsh --connect qemu:///system net-start "${LIBVIRT_NETWORK}" 2>&1)"; then
      network_info="$(virsh --connect qemu:///system net-info "${LIBVIRT_NETWORK}" 2>/dev/null || true)"
      if ! grep -Eq '^[[:space:]]*Active:[[:space:]]*yes[[:space:]]*$' <<<"${network_info}"; then
        printf '%s\n' "${start_error}" >&2
        die "Failed to start libvirt network: ${LIBVIRT_NETWORK}"
      fi
    fi
  fi

  virsh --connect qemu:///system net-autostart "${LIBVIRT_NETWORK}" >/dev/null
  log "Libvirt network is ready: ${LIBVIRT_NETWORK}"
}

main() {
  require_command virsh
  require_command grep
  [[ -f "${CREATE_SCRIPT}" ]] || die "Single-node script not found: ${CREATE_SCRIPT}"

  if [[ -z "${INSTALL_DISK}" ]]; then
    INSTALL_DISK="$(virsh --connect qemu:///system domblklist --details "${CLUSTER_NAME}" 2>/dev/null | awk '$2 == "disk" && ($3 ~ /^(vd|sd|xvd)[a-z]+$/ || $3 ~ /^nvme[0-9]+n[0-9]+$/ || $3 ~ /^mmcblk[0-9]+$/) { print "/dev/" $3; exit }')" || true
  fi

  bootstrap_libvirt

  if [[ -z "${NODE_IP}" ]]; then
    log "NODE_IP is not set; querying the DHCP lease for domain ${CLUSTER_NAME}"
    NODE_IP="$(virsh --connect qemu:///system domifaddr "${CLUSTER_NAME}" --source lease 2>/dev/null | awk 'NR > 2 && $4 ~ /^[0-9.]+\// { sub(/\/.*/, "", $4); print $4; exit }' || true)"
    [[ -n "${NODE_IP}" ]] || die "Could not determine the node IP from the DHCP lease; set NODE_IP to the node's address"
    log "Detected node IP: ${NODE_IP}"
  else
    log "Using configured node IP: ${NODE_IP}"
  fi

  CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-${NODE_IP}}"
  log "Control-plane VIP: ${CONTROL_PLANE_VIP}"
  log "Cluster: ${CLUSTER_NAME}; Talos: ${TALOS_VERSION}; Kubernetes: ${KUBERNETES_VERSION}"
  log "Install disk: ${INSTALL_DISK:-automatic}; wait timeout: ${WAIT_TIMEOUT_SECONDS}s"
  if [[ -n "${LOCAL_PATH_VERSION}" ]]; then
    log "Local-path provisioner version: ${LOCAL_PATH_VERSION}"
  else
    log "Local-path provisioner version: not specified"
  fi

  export CLUSTER_NAME TALOS_VERSION KUBERNETES_VERSION NODE_IP
  export CONTROL_PLANE_VIP INSTALL_DISK WAIT_TIMEOUT_SECONDS LOCAL_PATH_VERSION
  log "Starting single-node cluster creation with ${CREATE_SCRIPT}"
  exec bash "${CREATE_SCRIPT}" "$@"
}

main "$@"
