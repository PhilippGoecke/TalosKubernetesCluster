#!/bin/bash

# Abbrechen bei Fehlern
set -e

# --- KONFIGURATION ---
NAMESPACE="jitsi"
RELEASE_NAME="jitsi-meet"
# Ersetzen Sie dies durch Ihre tatsächliche Domain
PUBLIC_URL="meet.ihre-domain.de" 

echo "=== Starte Jitsi Meet Deployment auf Kubernetes ==="

# 1. Überprüfen, ob kubectl einsatzbereit ist
if ! kubectl cluster-info &> /dev/null; then
    echo "Fehler: Keine Verbindung zum Kubernetes-Cluster. Bitte 'kubectl' konfigurieren."
    exit 1
fi

# 2. Helm installieren falls nicht vorhanden
if ! command -v helm &> /dev/null; then
    echo "Helm wird installiert..."
    curl https://githubusercontent.com | bash
fi

# 3. Jitsi Helm Repository hinzufügen
echo "Füge Jitsi Helm Repository hinzu..."
helm repo add jitsi-contrib https://github.io
helm repo update

# 4. Namespace erstellen
echo "Erstelle Namespace: ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 5. Sichere Zufallspasswörter generieren
echo "Generiere Passwörter..."
JICOFO_AUTH_PASSWORD=$(openssl rand -hex 16)
JVB_AUTH_PASSWORD=$(openssl rand -hex 16)
JIGASI_AUTH_PASSWORD=$(openssl rand -hex 16)

# 6. Werte-Datei (values.yaml) dynamisch erstellen
echo "Erstelle Konfigurationsdatei (values.yaml)..."
cat <<EOF > jitsi-values.yaml
publicURL: "https://${PUBLIC_URL}"

# Authentifizierungs-Sicherheit
jicofo:
  auth:
    password: "${JICOFO_AUTH_PASSWORD}"

jvb:
  auth:
    password: "${JVB_AUTH_PASSWORD}"
  # Wichtig für Audio/Video: JVB benötigt direkten UDP-Zugriff (Standard NodePort)
  service:
    type: NodePort

jigasi:
  auth:
    password: "${JIGASI_AUTH_PASSWORD}"

# Ingress-Konfiguration (Anpassung je nach Ihrem Ingress-Controller)
ingress:
  enabled: true
  annotations:
    kubernetes.io/ingress.class: nginx
    cert-manager.io/cluster-issuer: "letsencrypt-prod" # Falls cert-manager genutzt wird
  hosts:
    - host: ${PUBLIC_URL}
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: jitsi-meet-tls
      hosts:
        - ${PUBLIC_URL}
EOF

# 7. Deployment via Helm ausführen
echo "Führe Helm Installation aus..."
helm upgrade --install ${RELEASE_NAME} jitsi-contrib/jitsi-meet \
  --namespace ${NAMESPACE} \
  -f jitsi-values.yaml

echo "========================================================"
echo " Jitsi Meet wurde erfolgreich im Namespace '${NAMESPACE}' installiert!"
echo " Es kann einige Minuten dauern, bis alle Pods bereit sind."
echo " Überprüfen Sie den Status mit:"
echo " kubectl get pods -n ${NAMESPACE}"
echo "========================================================"
