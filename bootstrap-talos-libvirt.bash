#!/usr/bin/env bash
# Bootstrap a six-node Talos Kubernetes cluster on a libvirt host.
#
# Default topology:
#   talos-cp-1 .. talos-cp-3       control-plane nodes
#   talos-worker-1 .. talos-worker-3 worker nodes
#
# Prerequisites on the *Linux libvirt host*:
#   bash, virsh, virt-install, curl, jq, talosctl
# The selected libvirt network must provide DHCP (the "default" network does).
#
# Examples:
#   ./bootstrap-talos-libvirt.bash
#   LIBVIRT_NETWORK=lab CLUSTER_NAME=lab ./bootstrap-talos-libvirt.bash
#   TALOS_VERSION=v1.14.1 ./bootstrap-talos-libvirt.bash create
#   ./bootstrap-talos-libvirt.bash destroy
#
# Optional environment variables:
#   CLUSTER_NAME          Kubernetes cluster name              (talos-lab)
#   LIBVIRT_NETWORK       Existing DHCP-enabled libvirt network (default)
#   TALOS_VERSION         Talos version used for ISO download  (v1.14.1)
#   TALOS_ISO_URL         Override the Image Factory ISO URL
#   TALOS_SCHEMATIC_ID    Reuse an existing Image Factory schematic
#   VM_MEMORY_MIB         RAM per VM                           (6144)
#   VM_VCPUS              vCPUs per VM                         (2)
#   VM_DISK_GIB           OS disk capacity per VM              (40)
#   VM_DIRECTORY          Directory for qcow2 VM disks
#   STATE_DIRECTORY       Directory for ISO, configs, kubeconfig
#   DISK_DEVICE           Target installation disk             (/dev/vda)
#   IP_TIMEOUT_SECONDS    DHCP lease wait timeout               (300)
#   SKIP_BOOTSTRAP=true   Only create VMs; do not configure Talos
#
# The Talos machine configuration is sent while every VM runs in maintenance
# mode. Talos then installs itself to DISK_DEVICE and restarts without the ISO.

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly ACTION="${1:-bootstrap}"

CLUSTER_NAME="${CLUSTER_NAME:-talos-lab}"
LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-default}"
TALOS_VERSION="${TALOS_VERSION:-v1.14.1}"
TALOS_SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-6144}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_DISK_GIB="${VM_DISK_GIB:-40}"
VM_DIRECTORY="${VM_DIRECTORY:-/var/lib/libvirt/images/${CLUSTER_NAME}}"
STATE_DIRECTORY="${STATE_DIRECTORY:-${PWD}/.talos-libvirt/${CLUSTER_NAME}}"
DISK_DEVICE="${DISK_DEVICE:-/dev/vda}"
IP_TIMEOUT_SECONDS="${IP_TIMEOUT_SECONDS:-300}"
SKIP_BOOTSTRAP="${SKIP_BOOTSTRAP:-false}"

readonly ISO_PATH="${STATE_DIRECTORY}/talos-${TALOS_VERSION}-amd64-custom.iso"
readonly KUBECONFIG_PATH="${STATE_DIRECTORY}/kubeconfig"
readonly CONTROL_PLANES=( "${CLUSTER_NAME}-controlplane-1" "${CLUSTER_NAME}-controlplane-2" "${CLUSTER_NAME}-controlplane-3" )
readonly WORKERS=( "${CLUSTER_NAME}-worker-1" "${CLUSTER_NAME}-worker-2" "${CLUSTER_NAME}-worker-3" )
readonly ALL_NODES=( "${CONTROL_PLANES[@]}" "${WORKERS[@]}" )

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<EOF
Usage: ${SCRIPT_NAME} [bootstrap|create|destroy]

  bootstrap  Download ISO, create VMs, configure Talos, and bootstrap Kubernetes.
  create     Download ISO and create VMs only.
  destroy    Stop and remove cluster VMs and their disks. State is retained.

Use environment variables documented in the script header to change defaults.
EOF
}

require_commands() {
  local command
  for command in "$@"; do
    command -v "$command" >/dev/null 2>&1 || die "Required command not found: ${command}"
  done
}

ensure_network() {
  # Allow the current user to access libvirt without sudo: sudo usermod -aG libvirt "$USER" (then log out and back in).
  virsh --connect qemu:///system net-info "${LIBVIRT_NETWORK}" >/dev/null 2>&1 ||
    die "Libvirt network does not exist: ${LIBVIRT_NETWORK}"

  if ! virsh --connect qemu:///system net-info "${LIBVIRT_NETWORK}" | grep -Eq '^[[:space:]]*Active:[[:space:]]*yes[[:space:]]*$'; then
    log "Starting libvirt network: ${LIBVIRT_NETWORK}"
    # The network can become active between the status check and net-start.
    local start_error
    if ! start_error=$(virsh --connect qemu:///system net-start "${LIBVIRT_NETWORK}" 2>&1); then
      if ! virsh --connect qemu:///system net-info "${LIBVIRT_NETWORK}" | grep -Eq '^[[:space:]]*Active:[[:space:]]*yes[[:space:]]*$'; then
        printf '%s\n' "${start_error}" >&2
        die "Failed to start libvirt network: ${LIBVIRT_NETWORK}"
      fi
    fi
  fi
}

download_iso() {
  local schematic_id iso_url

  mkdir -p "${STATE_DIRECTORY}"
  if [[ ! -s "${ISO_PATH}" ]]; then
    schematic_id="${TALOS_SCHEMATIC_ID}"
    if [[ -z "${schematic_id}" ]]; then
      log "Creating Image Factory schematic with iscsi-tools and util-linux-tools"
      schematic_id=$(curl --fail --silent --show-error --retry 3 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{"customization":{"systemExtensions":{"officialExtensions":["siderolabs/iscsi-tools","siderolabs/util-linux-tools"]}}}' \
        https://factory.talos.dev/schematics | jq --raw-output '.id')
      [[ -n "${schematic_id}" && "${schematic_id}" != "null" ]] || die "Image Factory did not return a schematic ID"
    fi
    iso_url="${TALOS_ISO_URL:-https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/metal-amd64.iso}"
    log "Downloading custom Talos ISO: ${iso_url}"
    curl --fail --location --retry 3 --output "${ISO_PATH}" "${iso_url}"
  else
    log "Using existing custom Talos ISO: ${ISO_PATH}"
  fi
}

create_vm() {
  local name="$1"

  if virsh dominfo "${name}" >/dev/null 2>&1; then
    die "VM already exists: ${name}. Refusing to overwrite it."
  fi

  log "Creating ${name}"
  virt-install \
    --connect qemu:///system \
    --name "${name}" \
    --memory "${VM_MEMORY_MIB}" \
    --vcpus "${VM_VCPUS}" \
    --cpu host-passthrough \
    --machine q35 \
    --disk "path=${VM_DIRECTORY}/${name}.qcow2,size=${VM_DISK_GIB},format=qcow2,bus=virtio" \
    --network "network=${LIBVIRT_NETWORK},model=virtio" \
    --cdrom "${ISO_PATH}" \
    --os-variant generic \
    --graphics vnc,listen=127.0.0.1,port=-1 \
    --console pty,target.type=serial \
    --noautoconsole \
    --import
}

create_cluster_vms() {
  if [[ ! -d "${VM_DIRECTORY}" ]]; then
    die "VM directory does not exist: ${VM_DIRECTORY}"
  fi
  local node
  for node in "${ALL_NODES[@]}"; do
    create_vm "${node}"
  done
}

node_ip() {
  local node="$1"
  local deadline=$((SECONDS + IP_TIMEOUT_SECONDS))
  local ip=""

  while (( SECONDS < deadline )); do
    ip="$(
      virsh --connect qemu:///system domifaddr "${node}" --source lease 2>/dev/null |
        awk '$3 == "ipv4" {sub(/\/.*/, "", $4); print $4; exit}'
    )"

    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return 0
    fi
    sleep 3
  done

  return 1
}

discover_node_ips() {
  declare -gA NODE_IPS=()
  local node

  log "Waiting up to ${IP_TIMEOUT_SECONDS}s for DHCP leases"
  for node in "${ALL_NODES[@]}"; do
    NODE_IPS["${node}"]="$(node_ip "${node}")" ||
      die "No DHCP IPv4 lease found for ${node}. Verify the '${LIBVIRT_NETWORK}' network has DHCP enabled."
    log "${node} => ${NODE_IPS[${node}]}"
  done
}

write_inventory() {
  local inventory="${STATE_DIRECTORY}/inventory.env"
  {
    printf '# Generated by %s on %s\n' "${SCRIPT_NAME}" "$(date --iso-8601=seconds)"
    printf 'export CLUSTER_NAME=%q\n' "${CLUSTER_NAME}"
    printf 'export TALOS_ENDPOINT=%q\n' "${NODE_IPS[${CONTROL_PLANES[0]}]}"
    local control_plane_ips=() node
    for node in "${CONTROL_PLANES[@]}"; do
      control_plane_ips+=("${NODE_IPS[${node}]}")
    done
    printf 'export CONTROL_PLANE_IPS=%q\n' "$(IFS=,; printf '%s' "${control_plane_ips[*]}")"
  } > "${inventory}"

  # The associative-array expansion above is not appropriate for a stable
  # comma-separated list, so append an explicit machine-readable mapping.
  local node
  for node in "${ALL_NODES[@]}"; do
    printf '%s=%s\n' "${node}" "${NODE_IPS[${node}]}" >> "${inventory}"
  done
  log "Wrote node inventory: ${inventory}"
}

configure_talos() {
  local control_plane_ip="${NODE_IPS[${CONTROL_PLANES[0]}]}"
  local node

  log "Generating Talos secrets and machine configurations"
  talosctl gen secrets --output-file "${STATE_DIRECTORY}/secrets.yaml"
  talosctl gen config \
    "${CLUSTER_NAME}" \
    "https://${control_plane_ip}:6443" \
    --with-secrets "${STATE_DIRECTORY}/secrets.yaml" \
    --output-dir "${STATE_DIRECTORY}/machine-config" \
    --install-disk "${DISK_DEVICE}" \
    --force

  for node in "${CONTROL_PLANES[@]}"; do
    log "Applying control-plane configuration to ${node} (${NODE_IPS[${node}]})"
    talosctl apply-config \
      --insecure \
      --nodes "${NODE_IPS[${node}]}" \
      --file "${STATE_DIRECTORY}/machine-config/controlplane.yaml"
  done

  for node in "${WORKERS[@]}"; do
    log "Applying worker configuration to ${node} (${NODE_IPS[${node}]})"
    talosctl apply-config \
      --insecure \
      --nodes "${NODE_IPS[${node}]}" \
      --file "${STATE_DIRECTORY}/machine-config/worker.yaml"
  done

  log "Waiting for the first control-plane node to become reachable"
  until talosctl --talosconfig "${STATE_DIRECTORY}/machine-config/talosconfig" \
    --nodes "${control_plane_ip}" \
    --endpoints "${control_plane_ip}" \
    health --wait-timeout 15m; do
    log "Control-plane API is not ready yet; retrying in 10 seconds"
    sleep 10
  done

  log "Bootstrapping the Talos control plane"
  talosctl --talosconfig "${STATE_DIRECTORY}/machine-config/talosconfig" \
    --nodes "${control_plane_ip}" \
    --endpoints "${control_plane_ip}" \
    bootstrap

  log "Retrieving kubeconfig"
  talosctl --talosconfig "${STATE_DIRECTORY}/machine-config/talosconfig" \
    --nodes "${control_plane_ip}" \
    --endpoints "${control_plane_ip}" \
    kubeconfig "${KUBECONFIG_PATH}" --force

  log "Cluster is bootstrapped."
  log "Use: export KUBECONFIG=${KUBECONFIG_PATH}"
  log "Then: kubectl get nodes"
}

destroy_cluster() {
  local node disk
  for node in "${ALL_NODES[@]}"; do
    if virsh --connect qemu:///system dominfo "${node}" >/dev/null 2>&1; then
      log "Removing ${node}"
      virsh --connect qemu:///system destroy "${node}" >/dev/null 2>&1 || true
      virsh --connect qemu:///system undefine "${node}" --nvram >/dev/null 2>&1 || virsh --connect qemu:///system undefine "${node}"
    fi

    disk="${VM_DIRECTORY}/${node}.qcow2"
    if [[ -e "${disk}" ]]; then
      log "Removing disk ${disk}"
      rm -f -- "${disk}"
    fi
  done
}

main() {
  case "${ACTION}" in
    bootstrap|create)
      require_commands virsh virt-install curl jq
      [[ "${ACTION}" == "create" || "${SKIP_BOOTSTRAP}" == "true" ]] || require_commands talosctl
      ensure_network
      download_iso
      create_cluster_vms
      discover_node_ips
      write_inventory

      if [[ "${ACTION}" == "bootstrap" && "${SKIP_BOOTSTRAP}" != "true" ]]; then
        configure_talos
      else
        log "VM creation complete. Node IPs are in ${STATE_DIRECTORY}/inventory.env"
      fi
      ;;
    destroy)
      require_commands virsh
      destroy_cluster
      rm -rf -- "${STATE_DIRECTORY}"
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "Unknown action: ${ACTION}"
      ;;
  esac
}

main
