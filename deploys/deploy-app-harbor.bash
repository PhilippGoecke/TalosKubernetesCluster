#!/bin/bash

# Aktiviert strikten Modus: Skript bricht bei Fehlern ab
set -euo pipefail

# --- KONFIGURATION ---
NAMESPACE="harbor"
RELEASE_NAME="harbor"
HELM_REPO_URL="https://helm.goharbor.io"
HARBOR_DOMAIN="harbor.example.com"      # Passen Sie Ihre Domain hier an
ADMIN_PASSWORD="AnEnterprisePassword123" # Ändern Sie dieses Passwort!
VALUES_FILE="harbor-values.yaml"

echo "===================================================="
echo " Starte Harbor-Infrastruktur-Bereitstellung"
echo "===================================================="

# 1. Helm Repository hinzufügen und aktualisieren
echo "--> Füge das offizielle Harbor Helm-Repository hinzu..."
helm repo add harbor "$HELM_REPO_URL"
helm repo update

# 2. Namespace erstellen (falls nicht vorhanden)
echo "--> Prüfe/Erstelle Namespace: $NAMESPACE..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 3. Dynamische Generierung der Konfigurationsdatei (values.yaml)
echo "--> Generiere minimale $VALUES_FILE für die Installation..."
cat <<EOF > "$VALUES_FILE"
expose:
  type: ingress
  ingress:
    hosts:
      core: $HARBOR_DOMAIN
    className: nginx
    annotations:
      ingress.kubernetes.io/ssl-redirect: "true"
      nginx.ingress.kubernetes.io/proxy-body-size: "0"

externalURL: https://$HARBOR_DOMAIN

harborAdminPassword: "$ADMIN_PASSWORD"

# Für Demozwecke wird standardmäßig 'unmanaged' Speicher verwendet. 
# Für die Produktion sollten Sie persistente Speicherklassen (StorageClass) konfigurieren.
persistence:
  enabled: true
  persistentVolumeClaim:
    registry:
      size: 50Gi
    jobservice:
      size: 10Gi
    database:
      size: 10Gi
    redis:
      size: 5Gi
    trivy:
      size: 10Gi
EOF

# 4. Harbor via Helm installieren oder aktualisieren
echo "--> Installiere Harbor via Helm..."
helm upgrade --install "$RELEASE_NAME" harbor/harbor \
  --namespace "$NAMESPACE" \
  --values "$VALUES_FILE" \
  --wait \
  --timeout 12m

echo "----------------------------------------------------"
echo " Harbor wurde erfolgreich übermittelt!"
echo "----------------------------------------------------"

# 5. Status der Komponenten überprüfen
echo "--> Warte auf die vollständige Betriebsbereitschaft der Pods..."
kubectl get pods -n "$NAMESPACE"

echo "===================================================="
echo " Bereitstellung abgeschlossen!"
echo " URL:      https://$HARBOR_DOMAIN"
echo " Benutzer: admin"
echo " Passwort: $ADMIN_PASSWORD"
echo "===================================================="
