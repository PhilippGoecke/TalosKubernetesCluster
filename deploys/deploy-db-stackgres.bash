#!/usr/bin/env bash

set -euo pipefail

# --- CONFIGURATION & LONGHORN PROFILE ---
NAMESPACE="stackgres-prod"
CHART_REPO_NAME="stackgres-charts"
CHART_REPO_URL="https://stackgres.io"
CLUSTER_NAME="pg-longhorn-cluster"
POSTGRES_VERSION="16"

# Node & Topology Constraints
REPLICAS=3 
STORAGE_CLASS="longhorn-postgres-sc"  # Optimized Custom StorageClass
STORAGE_SIZE="100Gi"
LONGHORN_REPLICAS="3"                 # Data block mirroring factor

# Compute Profile (Guaranteed QoS)
CPU_LIMIT="4"
CPU_REQUEST="2"
MEMORY_LIMIT="8Gi"
MEMORY_REQUEST="4Gi"

# --- HELPER FUNCTIONS ---
log() { echo -e "\033[1;32m[INFO]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
err() { echo -e "\033[1;31m[ERROR]\033[0m $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2; exit 1; }

# --- PRE-FLIGHT VERIFICATIONS ---
command -v kubectl >/dev/null 2>&1 || err "kubectl is missing."
command -v helm >/dev/null 2>&1 || err "helm is missing."
kubectl cluster-info >/dev/null 2>&1 || err "Unable to connect to cluster."

# Verify Longhorn Driver is active in the cluster
kubectl get deployment -n longhorn-system longhorn-driver-deployer >/dev/null 2>&1 || \
    err "Longhorn system driver not detected. Please install Longhorn before running this script."

# --- STEP 1: CREATE OPTIMIZED LONGHORN STORAGE CLASS ---
log "Creating production-optimized Longhorn StorageClass..."
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ${STORAGE_CLASS}
provisioner: driver.longhorn.io
allowVolumeExpansion: true
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
parameters:
  numberOfReplicas: "${LONGHORN_REPLICAS}"
  staleReplicaTimeout: "30"
  dataLocality: "best-effort" # Prioritizes executing reads from the local node
  fsType: "ext4"
EOF

# --- STEP 2: OPERATOR DEPLOYMENT ---
log "Syncing StackGres Helm repositories..."
helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}"
helm repo update

log "Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Installing StackGres Operator..."
helm upgrade --install stackgres-operator "${CHART_REPO_NAME}/stackgres-operator" \
    --namespace "${NAMESPACE}" \
    --set adminui.service.type=ClusterIP \
    --wait

# --- STEP 3: PROVISION HA POSTGRESQL ON LONGHORN ---
log "Deploying resource-guaranteed SGCluster backed by Longhorn storage..."
cat <<EOF | kubectl apply -f -
apiVersion: stackgres.io/v1
kind: SGCluster
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  instances: ${REPLICAS}
  postgres:
    version: "${POSTGRES_VERSION}"
  pods:
    scheduling:
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - stackgres
              topologyKey: "kubernetes.io/hostname"
    resources:
      requests:
        cpu: "${CPU_REQUEST}"
        memory: "${MEMORY_REQUEST}"
      limits:
        cpu: "${CPU_LIMIT}"
        memory: "${MEMORY_LIMIT}"
    persistentVolume:
      size: "${STORAGE_SIZE}"
      storageClassName: "${STORAGE_CLASS}" # Bound directly to our Longhorn profile
EOF

log "Deployment payload committed to the cluster API using Longhorn backend storage."
log "Monitor cluster status with: kubectl get pods -n ${NAMESPACE} -w"
