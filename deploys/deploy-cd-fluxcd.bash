#!/usr/bin/env bash

# Fehlerbehandlung: Skript stoppen, wenn ein Befehl fehlschlägt
set -euo pipefail

# ==========================================
# KONFIGURATION (Bitte anpassen)
# ==========================================
export GITHUB_USER="IHR_GITHUB_BENUTZERNAME"
export GITHUB_TOKEN="IHR_GITHUB_PERSONAL_ACCESS_TOKEN"

# Flux Repository-Einstellungen
REPO_NAME="flux-fleet-infra"
BRANCH="main"
CLUSTER_PATH="./clusters/my-cluster"

echo "=========================================="
echo " Starting FluxCD Deployment Pipeline"
echo "=========================================="

# 1. Überprüfen, ob kubectl verfügbar ist und Verbindung zum Cluster steht
echo "➜ Checking Kubernetes cluster connection..."
if ! kubectl cluster-info &> /dev/null; then
    echo "❌ Error: Cannot connect to Kubernetes cluster. Ensure your Kubeconfig is set."
    exit 1
fi
echo "✅ Connected to cluster successfully."

# 2. Flux CLI installieren (falls noch nicht vorhanden)
if ! command -v flux &> /dev/null; then
    echo "➜ Flux CLI not found. Installing via official script..."
    curl -s https://fluxcd.io/install.sh | sudo bash
    echo "✅ Flux CLI installed successfully."
else
    echo "✅ Flux CLI is already installed: $(flux --version)"
fi

# 3. Pre-flight Checks ausführen
echo "➜ Running Flux pre-flight checks on the cluster..."
if ! flux check --pre; then
    echo "❌ Error: Cluster does not meet requirements for FluxCD."
    exit 1
fi
echo "✅ Cluster pre-flight checks passed."

# 4. Validierung der Umgebungsvariablen
if [ "$GITHUB_USER" == "IHR_GITHUB_BENUTZERNAME" ] || [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Error: Please configure GITHUB_USER and GITHUB_TOKEN inside the script."
    exit 1
fi

# 5. FluxCD Bootstrap auf GitHub ausführen
echo "➜ Bootstrapping FluxCD into repository: ${GITHUB_USER}/${REPO_NAME}..."
flux bootstrap github \
  --owner="$GITHUB_USER" \
  --repository="$REPO_NAME" \
  --branch="$BRANCH" \
  --path="$CLUSTER_PATH" \
  --personal

echo "=========================================="
echo "🎉 FluxCD deployment completed successfully!"
echo "=========================================="

# 6. Status der installierten Komponenten anzeigen
echo "➜ Checking deployed Flux components status:"
flux check
