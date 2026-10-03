#!/usr/bin/env bash

# Talos bootstrap with Longhorn (fresh, unconfigured nodes)
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

# ==========================================
# CONFIGURATION & VARIABLES
# ==========================================
CLUSTER_NAME="${CLUSTER_NAME:-production-cluster}"
TALOS_VERSION="${TALOS_VERSION:-v1.14.1}" # Replace with your preferred Talos version
KUBERNETES_VERSION="${KUBERNETES_VERSION:-v1.36.1}" # Replace with your preferred Kubernetes version
CONTROL_PLANE_VIP="${CONTROL_PLANE_VIP:-192.168.168.175}" # Unused address on the control-plane subnet
CONTROL_PLANE_INTERFACE="${CONTROL_PLANE_INTERFACE:-eth0}" # Interface carrying the VIP on every control-plane node
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}" # Maximum time to wait for a node to become ready
LONGHORN_VERSION="${LONGHORN_VERSION:-1.10.1}" # Helm chart version; verify compatibility with your Kubernetes version
LONGHORN_TIMEOUT="${LONGHORN_TIMEOUT:-15m}"

# Set NODES in the environment as a space-separated list of "IP:ROLE" entries.
# Roles must be either "controlplane" or "worker"
IFS=' ' read -r -a NODES <<< "${NODES:-192.168.168.174:controlplane 192.168.168.212:controlplane 192.168.168.148:worker 192.168.168.111:worker}"

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
require_cmd curl
require_cmd jq
require_cmd kubectl
require_cmd helm

if [[ ! "${CONTROL_PLANE_VIP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "CONTROL_PLANE_VIP must be a valid IPv4 address: ${CONTROL_PLANE_VIP}"
fi

if [[ ${#NODES[@]} -eq 0 ]]; then
    fail "No nodes were defined in NODES. At least one node is required."
fi

# Validate the topology before changing any machines. Longhorn runs on workers.
WORKER_COUNT=0
CONTROL_PLANE_COUNT=0
for NODE in "${NODES[@]}"; do
    [[ "${NODE}" == *:* ]] || fail "Invalid node format '${NODE}'. Expected 'IP:ROLE'."
    [[ "${NODE%%:*}" != "${CONTROL_PLANE_VIP}" ]] || fail "The VIP must not be a node's physical IP."
    case "${NODE#*:}" in
        controlplane) ((CONTROL_PLANE_COUNT += 1)) ;;
        worker) ((WORKER_COUNT += 1)) ;;
        *) fail "Unknown role in '${NODE}'." ;;
    esac
done
(( CONTROL_PLANE_COUNT > 0 )) || fail "At least one control-plane node is required."
(( WORKER_COUNT > 0 )) || fail "At least one worker is required for Longhorn."
LONGHORN_REPLICAS=$((WORKER_COUNT < 3 ? WORKER_COUNT : 3))

mkdir -p "${CONFIG_DIR}"
log "🚀 Starting Talos Cluster Bootstrap for: ${CLUSTER_NAME}"

# Longhorn's v1 data engine needs these host extensions. The installer image
# installs them on fresh machines; already-installed machines need an explicit
# Talos upgrade to this image (changing machine.install.image is not an upgrade).
log "📦 Creating a Talos Image Factory schematic with Longhorn prerequisites..."
cat > "${CONFIG_DIR}/schematic.yaml" <<'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
EOF
SCHEMATIC_ID="$(curl --fail --silent --show-error --retry 3 \
    --connect-timeout 10 --max-time 120 \
    --header 'Content-Type: application/yaml' \
    --data-binary "@${CONFIG_DIR}/schematic.yaml" \
    https://factory.talos.dev/schematics | jq -er '.id')"
[[ "${SCHEMATIC_ID}" =~ ^[a-f0-9]{64}$ ]] || fail "Invalid Image Factory schematic ID."
INSTALLER_IMAGE="factory.talos.dev/installer/${SCHEMATIC_ID}:${TALOS_VERSION}"
log "Talos installer image: ${INSTALLER_IMAGE}"

# /var/lib/longhorn lives on Talos's persistent EPHEMERAL partition. Size the
# system disk appropriately; dedicated storage disks need separate provisioning.
jq -n --arg image "${INSTALLER_IMAGE}" '{machine: {
    install: {image: $image},
    kubelet: {extraMounts: [{
        destination: "/var/lib/longhorn",
        type: "bind",
        source: "/var/lib/longhorn",
        options: ["bind", "rshared", "rw"]
    }]}
}}' > "${CONFIG_DIR}/longhorn-machine-patch.yaml"
jq -n --arg interface "${CONTROL_PLANE_INTERFACE}" --arg vip "${CONTROL_PLANE_VIP}" \
    '{machine: {network: {interfaces: [{interface: $interface, vip: {ip: $vip}}]}}}' \
    > "${CONFIG_DIR}/vip-patch.yaml"

# ==========================================
# 1. GENERATE BASE CONFIGURATIONS
# ==========================================
if [[ ! -f "${CONFIG_DIR}/secrets.yaml" ]]; then
    log "📦 Generating base secrets and machine configurations..."
    talosctl gen secrets --output-file "${CONFIG_DIR}/secrets.yaml" --talos-version "${TALOS_VERSION}"
    log "✅ Secrets generated successfully."
fi
if [[ ! -f "${CONFIG_DIR}/controlplane.yaml" || ! -f "${CONFIG_DIR}/worker.yaml" || ! -f "${CONFIG_DIR}/talosconfig" ]]; then
    talosctl gen config "${CLUSTER_NAME}" "https://${CONTROL_PLANE_VIP}:6443" \
        --output-dir "${CONFIG_DIR}" \
        --force \
        --with-secrets "${CONFIG_DIR}/secrets.yaml" \
        --install-image "${INSTALLER_IMAGE}" \
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
    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while ! talosctl get machinestatus --insecure --nodes "${IP}" >/dev/null 2>&1; do
        if (( SECONDS >= WAIT_DEADLINE )); then
            fail "Timed out after ${WAIT_TIMEOUT_SECONDS}s waiting for ${IP} to become ready."
        fi
        log "   ${IP} is not ready yet; checking again..."
        sleep 2
    done
    log "✅ Node ${IP} is ready."

    if [[ "${ROLE}" == "controlplane" ]]; then
        log "🛠️ Applying control plane configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/controlplane.yaml" \
            --config-patch "@${CONFIG_DIR}/longhorn-machine-patch.yaml" \
            --config-patch "@${CONFIG_DIR}/vip-patch.yaml"
    else
        log "🛠️ Applying worker configuration..."
        talosctl apply-config --insecure --nodes "${IP}" --file "${CONFIG_DIR}/worker.yaml" \
            --config-patch "@${CONFIG_DIR}/longhorn-machine-patch.yaml"
    fi
done

if [[ ${CONTROL_PLANE_COUNT} -eq 0 ]]; then
    fail "No control plane nodes were defined. At least one node with role 'controlplane' is required."
fi

  log "Waiting for the first control-plane Talos API to become reachable"
    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  until talosctl --talosconfig "${CONFIG_DIR}/talosconfig" \
    --nodes "${FIRST_CP_IP}" \
    --endpoints "${FIRST_CP_IP}" \
    version >/dev/null 2>&1; do
    (( SECONDS < WAIT_DEADLINE )) || fail "Timed out waiting for the control-plane Talos API."
    log "Control-plane API is not ready yet; retrying in 10 seconds"
    sleep 10
  done
  log "✅ First control-plane Talos API is reachable."

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

# ==========================================
# 5. INSTALL LONGHORN
# ==========================================
export KUBECONFIG="${CONFIG_DIR}/kubeconfig"
kubectl wait --for=condition=Ready nodes --all --timeout="${WAIT_TIMEOUT_SECONDS}s"

# Fail clearly rather than deploying Longhorn without its host prerequisites.
for NODE in "${NODES[@]}"; do
    [[ "${NODE#*:}" == "worker" ]] || continue
    IP="${NODE%%:*}"
    EXTENSIONS="$(talosctl get extensions \
        --talosconfig "${CONFIG_DIR}/talosconfig" \
        --endpoints "${FIRST_CP_IP}" --nodes "${IP}" -o yaml)"
    for EXTENSION in iscsi-tools util-linux-tools; do
        [[ "${EXTENSIONS}" == *"${EXTENSION}"* ]] || \
            fail "${IP} is missing ${EXTENSION}. Upgrade it to ${INSTALLER_IMAGE} before installing Longhorn."
    done
done

log "📦 Installing Longhorn ${LONGHORN_VERSION} with ${LONGHORN_REPLICAS} replicas..."
kubectl create namespace longhorn-system --dry-run=client -o yaml | kubectl apply -f -
# Longhorn needs privileged pods and host mounts; limit this exemption to its namespace.
kubectl label namespace longhorn-system --overwrite \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged

helm repo add longhorn https://charts.longhorn.io --force-update
helm repo update longhorn
helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --version "${LONGHORN_VERSION}" \
    --set defaultSettings.defaultDataPath=/var/lib/longhorn \
    --set defaultSettings.defaultReplicaCount="${LONGHORN_REPLICAS}" \
    --set persistence.defaultClass=true \
    --set persistence.defaultClassReplicaCount="${LONGHORN_REPLICAS}" \
    --set defaultSettings.v2DataEngine=false \
    --wait --timeout "${LONGHORN_TIMEOUT}"
kubectl -n longhorn-system rollout status daemonset/longhorn-manager --timeout="${LONGHORN_TIMEOUT}"
kubectl -n longhorn-system rollout status daemonset/longhorn-csi-plugin --timeout="${LONGHORN_TIMEOUT}"
kubectl get storageclass longhorn

log "🎉 Success! Talos cluster '${CLUSTER_NAME}' and Longhorn are ready."
log "📂 Secrets and configurations saved to: ${CONFIG_DIR}"
log "💡 To interact with your cluster, run:"
log " export KUBECONFIG=${CONFIG_DIR}/kubeconfig"
log " kubectl get nodes -o wide"
log " kubectl -n longhorn-system get pods"
log "💡 Use storageClassName: longhorn in your PersistentVolumeClaims."
log "💡 Longhorn UI (local access only):"
log " kubectl -n longhorn-system port-forward service/longhorn-frontend 8080:80"
log "   Open http://localhost:8080"
log "⚠️ Replication is not a backup; configure an external Longhorn backup target."
