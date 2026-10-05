#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
set -eo pipefail

echo "========================================================="
echo " Deploying Metrics Server with --kubelet-insecure-tls "
echo "========================================================="

# 1. Prerequisites Check
if ! command -v kubectl &> /dev/null; then
    echo "❌ Error: 'kubectl' command line tool not found."
    exit 1
fi

if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Error: Cannot connect to the Kubernetes cluster. Check your kubeconfig."
    exit 1
fi

# 2. Apply the official, unpatched manifest directly from upstream
echo "🚀 Applying the latest official Metrics Server manifest..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 3. Native patch to inject the --kubelet-insecure-tls flag into container arguments
echo "🔧 Patching deployment natively to add --kubelet-insecure-tls..."
kubectl patch deployment metrics-server -n kube-system --type='json' -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/args/-",
    "value": "--kubelet-insecure-tls"
  }
]'

# 4. Wait for the deployment to become healthy
echo "⏳ Waiting for Metrics Server to roll out and become available..."
if kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=120s; then
    echo "✅ Metrics Server is up and running!"
else
    echo "❌ Timeout waiting for Metrics Server to become ready."
    exit 1
fi

# 5. Final verification buffer
echo "⏳ Sleeping 15 seconds to allow the first data collection loop..."
sleep 15

echo "========================================================="
echo " Fetching Node Resource Consumption: "
echo "========================================================="
if ! kubectl top nodes; then
    echo "⚠️ The metrics API is initialized but hasn't received data yet. Please try running 'kubectl top nodes' manually in 30 seconds."
fi
