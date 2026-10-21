#!/usr/bin/env bash
set -euo pipefail

# Requires Helm, kubectl, and access to an existing Kubernetes cluster.
# Optional: CILIUM_VERSION=1.x.y ./install-cilium.sh
for cmd in helm kubectl; do
	command -v "$cmd" >/dev/null 2>&1 || {
		printf 'Required command not found: %s\n' "$cmd" >&2
		exit 1
	}
done

kubectl cluster-info >/dev/null

helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium

version_args=()
if [[ -n "${CILIUM_VERSION:-}" ]]; then
	version_args+=(--version "$CILIUM_VERSION")
fi

# Install on a cluster prepared for Cilium; do not layer over another CNI.
helm upgrade --install cilium cilium/cilium \
	--namespace kube-system \
	"${version_args[@]}" \
	--set kubeProxyReplacement=true \
	--set enableExternalIPs=true \
	--wait \
	--timeout 10m

kubectl --namespace kube-system rollout status daemonset/cilium --timeout=5m
kubectl --namespace kube-system rollout status deployment/cilium-operator --timeout=5m

# Enable Hubble in a separate Helm upgrade after Cilium is ready.
helm upgrade cilium cilium/cilium \
	--namespace kube-system \
	"${version_args[@]}" \
	--reuse-values \
	--set hubble.enabled=true \
	--set hubble.relay.enabled=true \
	--set hubble.ui.enabled=true \
	--wait \
	--timeout 10m

kubectl --namespace kube-system rollout status deployment/hubble-relay --timeout=5m
kubectl --namespace kube-system rollout status deployment/hubble-ui --timeout=5m

printf '\nCilium and Hubble installed. To access the Hubble UI, run:\n'
printf 'kubectl --namespace kube-system port-forward service/hubble-ui 12000:80\n'
printf 'Then open http://localhost:12000\n'
