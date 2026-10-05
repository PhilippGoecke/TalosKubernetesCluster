#!/bin/bash

# Fehlerbehandlung: Skript bricht bei Fehlern ab, ungültige Variablen führen zum Stopp
set -euo pipefail

# --- CONFIGURATION ---
NAMESPACE="argocd"
# Optionale Version (Standard: latest stable). Für eine feste Version z.B. "v2.10.4" eintragen.
ARGOCD_VERSION="stable" 
MANIFEST_URL="https://githubusercontent.com{ARGOCD_VERSION}/manifests/install.yaml"

# --- HELPER FUNCTIONS ---
log() {
    echo -e "\033[1;32m[INFO]\033[0m $1"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $1"
}

error() {
    echo -e "\033[1;31m[ERROR]\033[0m $1"
    exit 1
}

# --- PREREQUISITES CHECK ---
log "Prüfe Systemvoraussetzungen..."
if ! command -v kubectl &> /dev/null; then
    error "kubectl ist nicht installiert. Bitte installieren Sie kubectl, bevor Sie dieses Skript ausführen."
fi

if ! kubectl cluster-info &> /dev/null; then
    error "Verbindung zum Kubernetes-Cluster fehlgeschlagen. Prüfen Sie Ihr Kubeconfig-File."
fi

# --- DEPLOYMENT ---
log "Erstelle Namespace '${NAMESPACE}' (falls nicht vorhanden)..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Lade ArgoCD Manifeste (${ARGOCD_VERSION}) und installiere Komponenten..."
# --server-side wird empfohlen, um Limitierungen der Annotation-Größe bei großen CRDs zu umgehen
kubectl apply -n "${NAMESPACE}" -f "${MANIFEST_URL}" --server-side

log "Warte darauf, dass die ArgoCD Deployments einsatzbereit sind..."
kubectl rollout status deployment/argocd-server -n "${NAMESPACE}" --timeout=300s

log "ArgoCD wurde erfolgreich installiert!"

# --- POST-INSTALLATION INFO ---
log "Rufe initiales Admin-Passwort ab..."
# Das Initialpasswort wird von ArgoCD verschlüsselt in einem K8s Secret abgelegt
INITIAL_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo "--------------------------------------------------------"
echo -e "\033[1;34mArgoCD Zugangsdaten:\033[0m"
echo "  URL:      http://localhost:8080 (Nach Port-Forwarding)"
echo "  Username: admin"
echo "  Password: ${INITIAL_PASSWORD}"
echo "--------------------------------------------------------"

log "Um die Web-Oberfläche lokal zu öffnen, führen Sie folgenden Befehl aus:"
echo "  kubectl port-forward svc/argocd-server -n ${NAMESPACE} 8080:443"
echo "--------------------------------------------------------"
