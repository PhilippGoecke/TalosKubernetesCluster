#!/bin/bash

# Abbrechen bei Fehlern
set -e

# --- KONFIGURATION ---
NAMESPACE="gitea"
RELEASE_NAME="gitea"
HELM_REPO_URL="https://dl.gitea.com/charts/"

# Admin-Benutzerdaten (Passen Sie diese vor der Ausführung an!)
ADMIN_USER="gitea_admin"
ADMIN_PASSWORD="EinSehrSicheresPasswort123!"
ADMIN_EMAIL="admin@example.com"

echo "=== Starte Gitea-Deployment auf Kubernetes ==="

# 1. Voraussetzungen prüfen
echo "Prüfe Werkzeuge..."
command -v kubectl >/dev/null 2>&1 || { echo "Fehler: kubectl wird benötigt, ist aber nicht installiert."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "Fehler: helm wird benötigt, ist aber nicht installiert."; exit 1; }

# 2. Namespace erstellen
echo "Erstelle Namespace '${NAMESPACE}'..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 3. K8s-Secret für Admin-Zugangsdaten anlegen
echo "Erstelle Secrets für Admin-Konto..."
kubectl create secret generic gitea-admin-secret \
  --namespace ${NAMESPACE} \
  --from-literal=username="${ADMIN_USER}" \
  --from-literal=password="${ADMIN_PASSWORD}" \
  --from-literal=email="${ADMIN_EMAIL}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Helm-Repository hinzufügen & aktualisieren
echo "Konfiguriere Helm-Repository..."
helm repo add gitea-charts ${HELM_REPO_URL}
helm repo update

# 5. Inline-Konfiguration (values.yaml) definieren
# Hier wird PostgreSQL als integrierte Datenbank aktiviert und das Admin-Secret verknüpft
cat <<EOF > /tmp/gitea-values.yaml
postgresql:
  enabled: true

gitea:
  admin:
    existingSecret: gitea-admin-secret
  config:
    APP_NAME: "Mein privater Gitea-Server"
    RUN_MODE: prod

service:
  http:
    type: ClusterIP
    port: 3000
  ssh:
    type: ClusterIP
    port: 22
EOF

# 6. Installation ausführen
echo "Installiere Gitea über Helm..."
helm upgrade --install ${RELEASE_NAME} gitea-charts/gitea \
  --namespace ${NAMESPACE} \
  --values /tmp/gitea-values.yaml \
  --wait

# Temporäre Datei aufräumen
rm /tmp/gitea-values.yaml

echo "=== Gitea erfolgreich bereitgestellt! ==="
echo "Verwenden Sie den folgenden Befehl, um Gitea lokal im Browser aufzurufen:"
echo "kubectl port-forward svc/${RELEASE_NAME}-http 3000:3000 -n ${NAMESPACE}"
echo "Öffnen Sie anschließend: http://localhost:3000"
