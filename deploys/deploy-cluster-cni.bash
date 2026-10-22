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
# Talos: machine config must set cluster.network.cni.name=none and
# cluster.proxy.disabled=true; KubePrism (localhost:7445) must be enabled.
helm upgrade --install cilium cilium/cilium \
	--namespace kube-system \
	"${version_args[@]}" \
	--set ipam.mode=kubernetes \
	--set kubeProxyReplacement=true \
	--set k8sServiceHost=localhost \
	--set k8sServicePort=7445 \
	--set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
	--set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
	--set cgroup.autoMount.enabled=false \
	--set cgroup.hostRoot=/sys/fs/cgroup \
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
