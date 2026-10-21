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

# Install Cilium as the cluster CNI before deploying ingress-nginx.
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update cilium
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --wait \
  --timeout 10m

kubectl rollout status daemonset/cilium \
  --namespace kube-system \
  --timeout=10m

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
echo "Talos cluster setup:"
echo "  - Generate/select the Talos kubeconfig with talosctl kubeconfig, then verify"
echo "    kubectl is using this cluster: kubectl get nodes. This script only needs"
echo "    kubectl and Helm; do not run it on a Talos node."
echo "  - This script installs Cilium as the cluster CNI and waits for it to be ready."
echo "  - For SERVICE_TYPE=LoadBalancer, install/configure a LoadBalancer provider"
echo "    such as MetalLB first and allocate an address range reachable by clients."
echo "    Otherwise use SERVICE_TYPE=NodePort and route to reachable Talos node IPs."
echo
echo "To access applications through this ingress controller, configure:"
echo "  - A Kubernetes Service for each application (usually ClusterIP)."
echo "  - An Ingress with ingressClassName: nginx, host/path rules, and a backend"
echo "    referencing the application's Service and port."
echo "  - DNS for each hostname pointing to the controller's external address; find"
echo "    it with: kubectl get service ${RELEASE}-controller -n ${NAMESPACE}"
echo "    If EXTERNAL-IP remains <pending>, the cluster has no LoadBalancer provider."
echo "    Configure a provider such as MetalLB (or your cloud provider's integration),"
echo "    then check: kubectl get svc ${RELEASE}-controller -n ${NAMESPACE}"
echo "    Do not set spec.externalIPs unless those IPs are already routed to the nodes."
echo "  - For HTTPS, an Ingress TLS entry and a matching TLS secret."
echo
echo "OPNsense with HAProxy (for clusters without a LoadBalancer IP):"
echo "  1. Install the HAProxy plugin in OPNsense (System > Firmware > Plugins;"
echo "     install os-haproxy), then enable it under Services > HAProxy."
echo "  2. Run this script with SERVICE_TYPE=NodePort, for example:"
echo "     SERVICE_TYPE=NodePort bash ./deploy-ingress.sh"
echo "     Then run: kubectl get svc ${RELEASE}-controller -n ${NAMESPACE}"
echo "     Record the HTTP and HTTPS NodePorts and the IP addresses of reachable"
echo "     Kubernetes nodes. Permit OPNsense-to-node traffic on those ports."
echo "  3. In Services > HAProxy > Settings, add a backend containing the node IPs"
echo "     as servers, all using the HTTP NodePort. Configure a TCP health check."
echo "     Create an HTTP frontend on the OPNsense interface and port 80, then"
echo "     assign that backend as its default backend. Preserve the Host header."
echo "  4. For HTTPS termination at OPNsense, add/import a certificate (commonly"
echo "     via the ACME Client plugin), make a port-443 SSL-offloading frontend"
echo "     using it, and send decrypted HTTP to the HTTP backend. Alternatively,"
echo "     use TCP mode to forward port 443 to the HTTPS NodePort and terminate TLS"
echo "     in ingress-nginx; configure the certificate in the Ingress TLS secret."
echo "  5. Point each application's DNS hostname to OPNsense's public address"
echo "     (and configure internal DNS similarly if needed). Allow inbound TCP"
echo "     ports 80/443 in OPNsense firewall rules; test externally."
echo ""
echo "With MetalLB or another LoadBalancer implementation, use the assigned"
echo "service IP instead of node IPs/NodePorts for the HAProxy backend."
