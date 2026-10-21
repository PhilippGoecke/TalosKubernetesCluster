#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: PIIK_PORT=8080 bash deploy-piik.sh registry.example.com/piik:v1.0.0
# Use the image and listening port documented by your Piik distribution.
# Optional environment variables: PIIK_IMAGE, PIIK_NAMESPACE, PIIK_PORT,
# PIIK_REPLICAS, PIIK_ROLLOUT_TIMEOUT. Uses the current kubectl context.

command -v kubectl >/dev/null 2>&1 || {
	echo 'Error: kubectl is required.' >&2
	exit 1
}

IMAGE="${1:-${PIIK_IMAGE:-ghcr.io/tntcrafthim/piik:latest}}"
NAMESPACE="${PIIK_NAMESPACE:-piik}"
PORT="${PIIK_PORT:-8080}"
REPLICAS="${PIIK_REPLICAS:-1}"
TIMEOUT="${PIIK_ROLLOUT_TIMEOUT:-180s}"

if [[ -z "$IMAGE" ]]; then
	echo "Usage: bash $0 <piik-image:tag> (or set PIIK_IMAGE)" >&2
	exit 1
fi
if [[ ! "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || ((${#NAMESPACE} > 63)); then
	echo 'Error: PIIK_NAMESPACE must be a valid Kubernetes namespace name.' >&2
	exit 1
fi
if [[ ! "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || ((PORT > 65535)); then
	echo 'Error: PIIK_PORT must be between 1 and 65535.' >&2
	exit 1
fi
if [[ ! "$REPLICAS" =~ ^[1-9][0-9]{0,3}$ ]]; then
	echo 'Error: PIIK_REPLICAS must be between 1 and 9999.' >&2
	exit 1
fi

echo "Deploying Piik to namespace '$NAMESPACE' on the current kubectl context."
kubectl cluster-info >/dev/null

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml |
	kubectl apply -f -

# Generate manifests with kubectl so image values are safely serialized.
kubectl create deployment piik \
	--namespace="$NAMESPACE" \
	--image="$IMAGE" \
	--port="$PORT" \
	--replicas="$REPLICAS" \
	--dry-run=client -o yaml |
	kubectl apply -f -

# The generated Service selects app=piik, matching the Deployment above.
kubectl create service clusterip piik \
	--namespace="$NAMESPACE" \
	--tcp="$PORT:$PORT" \
	--dry-run=client -o yaml |
	kubectl apply -f -

kubectl rollout status deployment/piik --namespace="$NAMESPACE" --timeout="$TIMEOUT"
kubectl get deployment,service,pods --namespace="$NAMESPACE" -l app=piik

printf '\nFor local access, run:\n  kubectl -n %q port-forward service/piik %q\n' \
	"$NAMESPACE" "$PORT:$PORT"
