#!/usr/bin/env bash

# Talos bootstrap script
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==========================================
# CONFIGURATION & VARIABLES
# ==========================================
CLUSTER_NAME="${CLUSTER_NAME:-singlenode-cluster}"
TALOS_VERSION="${TALOS_VERSION:-v1.14.4}" # Replace with your preferred Talos version
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.37.1}" # Replace with your preferred Kubernetes version
NODE_IP="${NODE_IP:-192.168.168.148}" # IP address of the single node
CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-${NODE_IP}}" # Kubernetes API endpoint
INSTALL_DISK="${INSTALL_DISK:-}" # Talos installation target; prompted when not set
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}" # Maximum time to wait for a node to become ready
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.31}" # local-path-provisioner version

CONFIG_DIR="${PWD}/talos-cluster-config-${CLUSTER_NAME}"

log() {
    printf '%s\n' "$*"
}

fail() {
    printf '❌ ERROR: %s\n' "$*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_cmd talosctl

if [[ ! "${CONTROL_PLANE_VIP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "CONTROL_PLANE_VIP must be a valid IPv4 address: ${CONTROL_PLANE_VIP}"
fi

if [[ ! "${NODE_IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "NODE_IP must be a valid IPv4 address: ${NODE_IP}"
fi

# Confirm the node is reachable through Talos's unauthenticated maintenance API
# before creating configuration or making any setup changes.
log "⏳ Verifying that ${NODE_IP} is reachable in maintenance mode..."
WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
until talosctl get disks --insecure --nodes "${NODE_IP}" >/dev/null 2>&1; do
    if (( SECONDS >= WAIT_DEADLINE )); then
        fail "${NODE_IP} did not become reachable in maintenance mode within ${WAIT_TIMEOUT_SECONDS}s."
    fi
    log "   Waiting for ${NODE_IP} to become reachable in maintenance mode..."
    sleep 2
done
log "✅ Node ${NODE_IP} is reachable and in maintenance mode."

mkdir -p "${CONFIG_DIR}"
log "🚀 Starting Talos Cluster Bootstrap for: ${CLUSTER_NAME}"

# ==========================================
# 1. GENERATE BASE CONFIGURATIONS
# ==========================================
if [[ ! -f "${CONFIG_DIR}/secrets.yaml" ]]; then
    log "⏳ Waiting for ${NODE_IP} to become ready so Talos can report its disks..."
    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while ! talosctl get machinestatus --insecure --nodes "${NODE_IP}" >/dev/null 2>&1; do
        if (( SECONDS >= WAIT_DEADLINE )); then
            fail "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ${NODE_IP} to become ready."
        fi
        log "   ${NODE_IP} is not ready yet; checking again..."
        sleep 2
    done

    log "💽 Disks reported by Talos on ${NODE_IP}:"
    talosctl get disks --insecure --nodes "${NODE_IP}" || fail "Could not retrieve disks from ${NODE_IP}."
    if [[ -z "${INSTALL_DISK}" ]]; then
        read -r -p "Enter the disk ID to use for Talos installation (e.g., /dev/sda or none): " INSTALL_DISK
    fi
    if [[ "${INSTALL_DISK,,}" == "none" ]]; then
        INSTALL_DISK=""
    fi
    if [[ -z "${INSTALL_DISK}" ]]; then
        log "No installation disk selected; Talos will not be installed to a disk."
    fi

    log "📦 Generating base secrets and machine configurations..."
    talosctl gen secrets --output-file "${CONFIG_DIR}/secrets.yaml" --talos-version "${TALOS_VERSION}"
    log "✅ Secrets generated successfully."
    
    log "⏳ Generating Talos machine configurations..."
    talosctl gen config "${CLUSTER_NAME}" "https://${CONTROL_PLANE_VIP}:6443" \
        --output-dir "${CONFIG_DIR}" \
        --with-secrets "${CONFIG_DIR}/secrets.yaml" \
        --kubernetes-version "${KUBERNETES_VERSION}" \
        --install-disk "${INSTALL_DISK}" \
        --config-patch-control-plane '{"cluster":{"allowSchedulingOnControlPlanes":true,"network":{"cni":{"name":"none"}},"proxy":{"disabled":true}},"machine":{"features":{"kubePrism":{"enabled":true,"port":7445}},"kubelet":{"extraMounts":[{"destination":"/var/local-path-provisioner","type":"bind","source":"/var/local-path-provisioner","options":["bind","rshared","rw"]}]}}}'
    log "✅ Base configuration generated successfully."
else
    log "ℹ️ Base configurations already exist. Skipping generation."
fi

# ==========================================
# 2. APPLY CONFIGURATIONS TO NODES
# ==========================================
FIRST_CP_IP="${NODE_IP}"
log "🔧 Processing the single control-plane node ${NODE_IP}..."
log "⏳ Waiting for ${NODE_IP} to become ready before applying configuration..."
WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while ! talosctl get machinestatus --insecure --nodes "${NODE_IP}" >/dev/null 2>&1; do
    if (( SECONDS >= WAIT_DEADLINE )); then
        fail "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ${NODE_IP} to become ready."
    fi
    log "   ${NODE_IP} is not ready yet; checking again..."
    sleep 2
done
log "✅ Node ${NODE_IP} is ready."
log "🛠️ Applying single-node control plane configuration..."
talosctl apply-config --insecure --nodes "${NODE_IP}" --file "${CONFIG_DIR}/controlplane.yaml" --mode=reboot

log "Waiting for the single-node Talos API to become reachable"
until talosctl --talosconfig "${CONFIG_DIR}/talosconfig" \
    --nodes "${FIRST_CP_IP}" \
    --endpoints "${FIRST_CP_IP}" \
    version >/dev/null 2>&1; do
    log "Talos API is not ready yet; retrying in 10 seconds"
    sleep 10
done
log "✅ Talos API is reachable."

# ==========================================
# 3. BOOTSTRAP THE CLUSTER
# ==========================================
log "⏳ Waiting for the control plane node to become ready before bootstrapping..."
WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
while ! talosctl get machinestatus \
    --talosconfig "${CONFIG_DIR}/talosconfig" \
    --endpoints "${FIRST_CP_IP}" \
    --nodes "${FIRST_CP_IP}" >/dev/null 2>&1; do
    if (( SECONDS >= WAIT_DEADLINE )); then
        fail "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ${FIRST_CP_IP} to become ready."
    fi
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

log "💾 Enabling local storage (local-path-provisioner ${LOCAL_PATH_VERSION})..."
require_cmd kubectl
export KUBECONFIG="${CONFIG_DIR}/kubeconfig"
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: local-path-storage
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
EOF
kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage patch deployment local-path-provisioner --type=strategic \\
    -p '{"spec":{"template":{"spec":{"containers":[{"name":"local-path-provisioner","securityContext":{"allowPrivilegeEscalation":false}}]}}}}'
kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=300s
log "✅ Default StorageClass 'local-path' is ready for PVCs."

log "🎉 Success! Your Talos cluster '${CLUSTER_NAME}' is bootstrapping with these settings:"
log "   CLUSTER_NAME=${CLUSTER_NAME}"
log "   TALOS_VERSION=${TALOS_VERSION}"
log "   KUBERNETES_VERSION=${KUBERNETES_VERSION}"
log "   NODE_IP=${NODE_IP}"
log "   CONTROL_PLANE_VIP=${CONTROL_PLANE_VIP}"
log "   INSTALL_DISK=${INSTALL_DISK:-none}"
log "   WAIT_TIMEOUT_SECONDS=${WAIT_TIMEOUT_SECONDS}"
log "   LOCAL_PATH_VERSION=${LOCAL_PATH_VERSION}"
log "📂 Secrets and configurations saved to: ${CONFIG_DIR}"
log "💡 To interact with your cluster, run:"
log " export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
log " kubectl get nodes -o wide"
log "💡 To clean up the cluster, you can run:"
log " talosctl reset --talosconfig ${CONFIG_DIR}/talosconfig --nodes ${FIRST_CP_IP}"
