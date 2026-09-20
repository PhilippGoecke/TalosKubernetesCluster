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
    echo "ℹ️ Secrets generated."
    talosctl gen config "${CLUSTER_NAME}" "https://${CONTROL_PLANE_VIP}:6443" \
        --output-dir "${CONFIG_DIR}" \
        --with-secrets "${CONFIG_DIR}/secrets.yaml"
    echo "ℹ️ Base configuration generated."
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

        echo " Apply control plane configuration"
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/controlplane.yaml"

    elif [ "${ROLE}" == "worker" ]; then
        echo " Apply worker configuration"
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/worker.yaml"
    else
        echo "❌ Unknown role '${ROLE}' for node ${IP}. Skipping."
    fi
done

# ==========================================
# 3. BOOTSTRAP THE CLUSTER
# ==========================================
echo "⏳ Waiting 30 seconds for control plane nodes to initialize before bootstrapping..."
sleep 30

echo "⚡ Initializing the Kubernetes cluster via ${FIRST_CP_IP}..."
# Configure local talosctl to point to the first controlplane node
talosctl config endpoint "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"
talosctl config node "${FIRST_CP_IP}" --talosconfig "${CONFIG_DIR}/talosconfig"

# Trigger the one-time bootstrap
talosctl bootstrap --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${FIRST_CP_IP}"

# ==========================================
# 4. FETCH KUBECONFIG
# ==========================================
echo "⏳ Waiting 60 seconds for Kubernetes API to come online..."
sleep 60

echo "🔑 Fetching the kubeconfig..."
talosctl kubeconfig "${CONFIG_DIR}/kubeconfig" --talosconfig "${CONFIG_DIR}/talosconfig" --nodes "${FIRST_CP_IP}"

echo "✅ Success! Your Talos cluster '${CLUSTER_NAME}' is bootstrapping."
echo "📂 Secrets and configurations saved to: ${CONFIG_DIR}"
echo "💡 To interact with your cluster, run:"
echo " export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
echo " kubectl get nodes -o wide"
