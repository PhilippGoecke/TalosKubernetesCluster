#!/usr/bin/env bash
set -euo pipefail

# Usage: ./deploy-metallb.sh <address-range>
# Example: ./deploy-metallb.sh 192.168.168.240-192.168.168.250

version="${METALLB_VERSION:-v0.14.9}"
address_range="${1:-${METALLB_IP_RANGE:-}}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Error: kubectl is required." >&2
  exit 1
fi

if [[ -z "$address_range" ]]; then
  echo "Usage: $0 <address-range>" >&2
  exit 1
fi

kubectl cluster-info >/dev/null
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${version}/config/manifests/metallb-native.yaml"
kubectl -n metallb-system rollout status deployment/controller --timeout=180s

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-address-pool
  namespace: metallb-system
spec:
  addresses:
    - "${address_range}"
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2-advertisement
  namespace: metallb-system
EOF

echo "MetalLB ${version} deployed with address pool ${address_range}."
