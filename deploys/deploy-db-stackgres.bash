#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and catch pipeline failures.
set -euo pipefail

# --- CONFIGURATION ---
NAMESPACE="stackgres"
CHART_REPO_NAME="stackgres-charts"
CHART_REPO_URL="https://stackgres.io/downloads/stackgres-k8s/stackgres/helm/"
CLUSTER_NAME="postgres-cluster"
POSTGRES_VERSION="16" # Can also use 'latest'
STORAGE_SIZE="10Gi"
REPLICAS=2

# --- HELPER FUNCTIONS ---
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

error_exit() {
    echo -e "\033[1;31m[ERROR]\033[0m $1" >&2
    exit 1
}

# --- PREREQUISITE CHECKS ---
log "Checking required CLI tools..."
command -v kubectl >/dev/null 2>&1 || error_exit "kubectl is required but not installed."
command -v helm >/dev/null 2>&1 || error_exit "helm is required but not installed."

# Verify cluster connectivity
kubectl cluster-info >/dev/null 2>&1 || error_exit "Cannot connect to the Kubernetes cluster. Check your kubeconfig."

# --- STEP 1: ADD HELM REPOSITORY ---
log "Adding StackGres Helm repository..."
helm repo add "${CHART_REPO_NAME}" "${CHART_REPO_URL}"
helm repo update

# --- STEP 2: INSTALL STACKGRES OPERATOR ---
log "Creating namespace '${NAMESPACE}' if it doesn't exist..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Installing StackGres Operator via Helm..."
# Installs the operator and configures the Web UI Console to use a LoadBalancer
helm upgrade --install stackgres-operator "${CHART_REPO_NAME}/stackgres-operator" \
    --namespace "${NAMESPACE}" \
    --set adminui.service.type=LoadBalancer \
    --wait

log "Waiting for StackGres Operator deployments to be fully ready..."
kubectl wait --namespace "${NAMESPACE}" \
    --for=condition=available \
    deployment/stackgres-operator \
    --timeout=300s

# --- STEP 3: DEPLOY POSTGRESQL CLUSTER (SGCluster) ---
log "Deploying StackGres PostgreSQL Cluster (${CLUSTER_NAME})..."
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
    persistentVolume:
      size: "${STORAGE_SIZE}"
EOF

log "Waiting for PostgreSQL instances to provision..."
kubectl wait --namespace "${NAMESPACE}" \
    --for=jsonpath='{.status.readyInstances}'="${REPLICAS}" \
    sgcluster/"${CLUSTER_NAME}" \
    --timeout=400s || log "Cluster is still provisioning. Check progress manually via 'kubectl get pods -n ${NAMESPACE}'"

# --- STEP 4: FETCH ACCESS CREDENTIALS ---
log "Retrieving Web Console login credentials..."
UI_USER=$(kubectl get secret stackgres-restapi-admin -n "${NAMESPACE}" -o jsonpath="{.data.username}" | base64 --decode)
UI_PASSWORD=$(kubectl get secret stackgres-restapi-admin -n "${NAMESPACE}" -o jsonpath="{.data.password}" | base64 --decode)

echo "--------------------------------------------------------"
echo " StackGres Deployment Successful!"
echo "--------------------------------------------------------"
echo " Web UI Admin Username: ${UI_USER}"
echo " Web UI Admin Password: ${UI_PASSWORD}"
echo ""
echo " To access the UI locally via port-forwarding, run:"
echo " kubectl port-forward -n ${NAMESPACE} deployment/stackgres-operator 8443:8443"
echo " Then navigate to: https://localhost:8443/admin/"
echo "--------------------------------------------------------"
