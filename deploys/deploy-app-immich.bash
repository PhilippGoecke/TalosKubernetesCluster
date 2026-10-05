#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# Configuration Variables
NAMESPACE="immich"
RELEASE_NAME="immich"
CHART_REPO_URL="https://immich.app"
CHART_NAME="immich/immich"

# 1. Check if kubectl is installed
if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: kubectl is not installed. Please install it before running this script."
    exit 1
fi

# 2. Check if helm is installed
if ! command -v helm &> /dev/null; then
    echo "❌ Error: Helm is not installed. Please install it before running this script."
    exit 1
fi

# 3. Create Namespace if it doesn't exist
echo "🚀 Creating namespace '${NAMESPACE}'..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 4. Add and Update Helm Repository
echo "📦 Adding Immich Helm repository..."
helm repo add immich ${CHART_REPO_URL}
echo "🔄 Updating Helm repositories..."
helm repo update

# 5. Generate a secure random database password
DB_PASSWORD=$(openssl rand -base64 18)

# 6. Install Immich using Helm with custom configurations
echo "⚡ Deploying Immich to Kubernetes via Helm..."
helm upgrade --install ${RELEASE_NAME} ${CHART_NAME} \
  --namespace ${NAMESPACE} \
  --set database.password="${DB_PASSWORD}" \
  --set env.jwtSecret="$(openssl rand -base64 24)" \
  --set immich.persistence.library.enabled=true \
  --set immich.persistence.library.size=100Gi

echo "========================================================="
echo "🎉 Immich deployment initiated successfully!"
echo "========================================================="
echo "📌 Namespace: ${NAMESPACE}"
echo "🔑 Auto-generated DB Password: ${DB_PASSWORD}"
echo "📈 Track deployment status using:"
echo "   kubectl get pods -n ${NAMESPACE} -w"
echo "========================================================="
