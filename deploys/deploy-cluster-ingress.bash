#!/usr/bin/env bash
set -euo pipefail

# Deploy ingress-nginx to the current Kubernetes cluster using Helm.
NAMESPACE="${NAMESPACE:-ingress-nginx}"
RELEASE="${RELEASE:-ingress-nginx}"
SERVICE_TYPE="${SERVICE_TYPE:-LoadBalancer}"

for cmd in helm kubectl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is required." >&2
    exit 1
  fi
done

kubectl cluster-info >/dev/null
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update
helm repo update ingress-nginx

helm upgrade --install "$RELEASE" ingress-nginx/ingress-nginx \
  --namespace "$NAMESPACE" \
  --create-namespace \
  --set "controller.service.type=$SERVICE_TYPE" \
  --wait \
  --timeout 10m

kubectl rollout status "deployment/${RELEASE}-controller" \
  --namespace "$NAMESPACE" \
  --timeout=10m

echo "Ingress controller deployed in namespace '$NAMESPACE'."

echo
echo "To access applications through this ingress controller, configure:"
echo "  - A Kubernetes Service for each application (usually ClusterIP)."
echo "  - An Ingress with ingressClassName: nginx, host/path rules, and a backend"
echo "    referencing the application's Service and port."
echo "  - DNS for each hostname pointing to the controller's external address; find"
echo "    it with: kubectl get service ${RELEASE}-controller -n ${NAMESPACE}"
echo "  - For HTTPS, an Ingress TLS entry and a matching TLS secret."
