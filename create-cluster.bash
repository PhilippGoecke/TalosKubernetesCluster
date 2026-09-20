#!/usr/bin/env bash

# Hardened Talos bootstrap script
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==========================================
# CONFIGURATION & VARIABLES
# ==========================================
CLUSTER_NAME="production-cluster"
TALOS_VERSION="v1.14.1" # Replace with your preferred Talos version
KUBERNETES_VERSION="v1.36.1" # Replace with your preferred Kubernetes version
CONTROL_PLANE_VIP="192.168.168.212" # Shared Virtual IP for the Control Plane API

# Define nodes using an array format: "IP:ROLE"
# Roles must be either "controlplane" or "worker"
NODES=(
    "192.168.168.212:controlplane"
    "192.168.168.148:worker"
    "192.168.168.111:worker"
)

CONFIG_DIR="${PWD}/talos-cluster-config-${CLUSTER_NAME}"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd talosctl

if [[ ! "${CONTROL_PLANE_VIP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "CONTROL_PLANE_VIP must be a valid IPv4 address: ${CONTROL_PLANE_VIP}"
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
    fail "No nodes were defined in NODES. At least one node is required."
fi

mkdir -p "${CONFIG_DIR}"
log "🚀 Starting Talos Cluster Bootstrap for: ${CLUSTER_NAME}"

# ==========================================
# 1. GENERATE BASE CONFIGURATIONS
# ==========================================
if [[ ! -f "${CONFIG_DIR}/secrets.yaml" ]]; then
    log "📦 Generating base secrets and machine configurations..."
    talosctl gen secrets --output-file "${CONFIG_DIR}/secrets.yaml" --talos-version "${TALOS_VERSION}"
    log "✅ Secrets generated successfully."
    talosctl gen config "${CLUSTER_NAME}" "https://${CONTROL_PLANE_VIP}:6443" \
        --output-dir "${CONFIG_DIR}" \
        --with-secrets "${CONFIG_DIR}/secrets.yaml" \
        --kubernetes-version "${KUBERNETES_VERSION}"
    log "✅ Base configuration generated successfully."
else
    log "ℹ️ Base configurations already exist. Skipping generation."
fi

# ==========================================
# 2. APPLY CONFIGURATIONS TO NODES
# ==========================================
FIRST_CP_IP=""
CONTROL_PLANE_COUNT=0

for NODE in "${NODES[@]}"; do
    [[ "${NODE}" == *:* ]] || fail "Invalid node format '${NODE}'. Expected 'IP:ROLE'."

    IP="${NODE%%:*}"
    ROLE="${NODE#*:}"

    case "${ROLE}" in
        controlplane)
            ((CONTROL_PLANE_COUNT += 1))
            if [[ -z "${FIRST_CP_IP}" ]]; then
                FIRST_CP_IP="${IP}"
            fi
            ;;
        worker)
            ;;
        *)
            fail "Unknown role '${ROLE}' for node '${IP}'. Allowed roles: controlplane, worker"
            ;;
    esac

    log "🔧 Processing node ${IP} as a ${ROLE}..."

    log "⏳ Waiting for ${IP} to become ready before applying configuration..."
    until talosctl get machinestatus --insecure --nodes "${IP}" >/dev/null 2>&1; do
        log "   ${IP} is not ready yet; checking again..."
        sleep 2
    done
    log "✅ Node ${IP} is ready."

    if [[ "${ROLE}" == "controlplane" ]]; then
        log "🛠️ Applying control plane configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/controlplane.yaml"
    else
        log "🛠️ Applying worker configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/worker.yaml"
    fi
done

if [[ ${CONTROL_PLANE_COUNT} -eq 0 ]]; then
    fail "No control plane nodes were defined. At least one node with role 'controlplane' is required."
fi

# ==========================================
# 3. BOOTSTRAP THE CLUSTER
# ==========================================
log "⏳ Waiting for the control plane node to become ready before bootstrapping..."
until talosctl get machinestatus --insecure --nodes "${FIRST_CP_IP}" >/dev/null 2>&1; do
    log "   ${FIRST_CP_IP} is not ready yet; checking again..."
    sleep 2
done
log "✅ Control plane node ${FIRST_CP_IP} is ready."

log "⚡ Initializing the Kubernetes cluster via ${FIRST_CP_IP}..."
if [[ -z "${FIRST_CP_IP}" ]]; then
    fail "No control plane node was configured; cannot bootstrap the cluster."
fi

log "🔗 Configuring talosctl to use control-plane endpoint: ${FIRST_CP_IP}"
talosctl config endpoint "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"
log "🖥️ Selecting ${FIRST_CP_IP} as the active Talos node"
talosctl config node "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"

log "🚀 Sending the one-time bootstrap request to ${FIRST_CP_IP}..."
log "   This initializes the Talos control plane and creates the Kubernetes datastore."
log "   The command may take a moment while the node initializes."
talosctl bootstrap \
    --talosconfig "${CONFIG_DIR}/talosconfig" \
    --endpoints "${FIRST_CP_IP}" \
    --nodes "${FIRST_CP_IP}"
log "✅ Bootstrap request completed successfully for ${FIRST_CP_IP}."

# ==========================================
# 4. FETCH KUBECONFIG
# ==========================================
log "⏳ Waiting for the Kubernetes API to become healthy..."
talosctl health \
    --talosconfig "${CONFIG_DIR}/talosconfig" \
    --endpoints "${FIRST_CP_IP}" \
    --nodes "${FIRST_CP_IP}" \
    --wait-timeout 10m

log "🔑 Fetching the kubeconfig..."
talosctl kubeconfig "${CONFIG_DIR}/kubeconfig" --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${FIRST_CP_IP}"

log "✅ Success! Your Talos cluster '${CLUSTER_NAME}' is bootstrapping."
log "📂 Secrets and configurations saved to: ${CONFIG_DIR}"
log "💡 To interact with your cluster, run:"
log " export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
log " kubectl get nodes -o wide"
