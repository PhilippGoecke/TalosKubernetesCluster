#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -e

# ==========================================
# CONFIGURATION & VARIABLES
# ==========================================
CLUSTER_NAME="production-cluster"
TALOS_VERSION="v1.14.1" # Replace with your preferred Talos version
CONTROL_PLANE_VIP="192.168.168.148" # The shared Virtual IP for the Control Plane API

# Define nodes using an associative-like array format: "IP:ROLE"
# Roles must be either "controlplane" or "worker"
NODES=(
    "192.168.168.148:controlplane"
    "192.168.168.111:worker"
)

# Output directory for generated configurations
CONFIG_DIR="$(pwd)/talos-cluster-config-$CLUSTER_NAME"
mkdir -p "${CONFIG_DIR}"

echo "🚀 Starting Talos Cluster Bootstrap for: ${CLUSTER_NAME}"

# ==========================================
# 1. GENERATE BASE CONFIGURATIONS
# ==========================================
if [ ! -f "${CONFIG_DIR}/secrets.yaml" ]; then
    echo "📦 Generating base secrets and machine configurations..."
    talosctl gen secrets --output-file "${CONFIG_DIR}/secrets.yaml" --talos-version "$TALOS_VERSION"
    echo "✅ Secrets generated successfully."
    talosctl gen config "${CLUSTER_NAME}" "https://${CONTROL_PLANE_VIP}:6443" \
        --output-dir "${CONFIG_DIR}" \
        --with-secrets "${CONFIG_DIR}/secrets.yaml"
    echo "✅ Base configuration generated successfully."
else
    echo "ℹ️ Base configurations already exist. Skipping generation."
fi

# ==========================================
# 2. APPLY CONFIGURATIONS TO NODES
# ==========================================
FIRST_CP_IP=""

for NODE in "${NODES[@]}"; do
    IP="${NODE%%:*}"
    ROLE="${NODE#*:}"

    echo "🔧 Processing node ${IP} as a ${ROLE}..."

    if [ "${ROLE}" == "controlplane" ]; then
        # Capture the first control plane node to run the bootstrap command against later
        if [ -z "${FIRST_CP_IP}" ]; then
            FIRST_CP_IP="${IP}"
        fi

        echo "🛠️ Applying control plane configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/controlplane.yaml"

    elif [ "${ROLE}" == "worker" ]; then
        echo "🛠️ Applying worker configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/worker.yaml"
    else
        echo "❌ Unknown role '${ROLE}' for node ${IP}. Skipping."
    fi
done

# ==========================================
# 3. BOOTSTRAP THE CLUSTER
# ==========================================
echo "⏳ Waiting for the control plane node to become ready before bootstrapping..."
until talosctl get machinestatus --insecure --nodes "${FIRST_CP_IP}" >/dev/null 2>&1; do
    echo "   ${FIRST_CP_IP} is not ready yet; checking again..."
    sleep 2
done
echo "✅ Control plane node ${FIRST_CP_IP} is ready."

echo "⚡ Initializing the Kubernetes cluster via ${FIRST_CP_IP}..."
# Configure local talosctl to point to the first controlplane node
if [ -z "${FIRST_CP_IP}" ]; then
    echo "❌ No control plane node was configured; cannot bootstrap the cluster." >&2
    exit 1
fi

echo "🔗 Configuring talosctl to use control-plane endpoint: ${FIRST_CP_IP}"
talosctl config endpoint "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"
echo "🖥️ Selecting ${FIRST_CP_IP} as the active Talos node"
talosctl config node "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"

# Trigger the one-time bootstrap against the selected control-plane endpoint.
echo "🚀 Sending the one-time bootstrap request to ${FIRST_CP_IP}..."
echo "   This initializes the Talos control plane and creates the Kubernetes datastore."
echo "   The command may take a moment while the node initializes."
talosctl bootstrap \
    --talosconfig "${CONFIG_DIR}/talosconfig" \
    --endpoints "${FIRST_CP_IP}" \
    --nodes "${FIRST_CP_IP}"
echo "✅ Bootstrap request completed successfully for ${FIRST_CP_IP}."

# ==========================================
# 4. FETCH KUBECONFIG
# ==========================================
echo "⏳ Waiting for the Kubernetes API to become healthy..."
talosctl health \
    --talosconfig "${CONFIG_DIR}/talosconfig" \
    --endpoints "${FIRST_CP_IP}" \
    --nodes "${FIRST_CP_IP}" \
    --wait-timeout 10m

echo "🔑 Fetching the kubeconfig..."
talosctl kubeconfig "${CONFIG_DIR}/kubeconfig" --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${FIRST_CP_IP}"

echo "✅ Success! Your Talos cluster '${CLUSTER_NAME}' is bootstrapping."
echo "📂 Secrets and configurations saved to: ${CONFIG_DIR}"
echo "💡 To interact with your cluster, run:"
echo " export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
echo " kubectl get nodes -o wide"
