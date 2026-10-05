#!/usr/bin/env bash

# Abbrechen bei Fehlern
set -euo pipefail

# --- KONFIGURATION ---
NAMESPACE_TRAEFIK="traefik"
NAMESPACE_APP="default"
DOMAIN="whoami.127.0.0.1.nip.io" # Nutzt nip.io für lokales Wildcard-Routing

echo "🚀 Starte Traefik und Whoami Bereitstellung..."

# 1. Traefik Helm-Repository hinzufügen & aktualisieren
echo "📦 Füge Traefik Helm-Repository hinzu..."
helm repo add traefik https://traefik.github.io/charts
helm repo update

# 2. Traefik installieren
echo "⚙️ Installiere Traefik Ingress Controller im Namespace '${NAMESPACE_TRAEFIK}'..."
helm upgrade --install traefik traefik/traefik \
  --namespace "${NAMESPACE_TRAEFIK}" \
  --create-namespace \
  --set providers.kubernetesIngress.publishedService.enabled=true \
  --wait

# 3. Whoami Deployment und Service erstellen
echo "🐳 Erstelle Whoami Anwendung im Namespace '${NAMESPACE_APP}'..."
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: whoami
  namespace: ${NAMESPACE_APP}
  labels:
    app: whoami
spec:
  replicas: 2
  selector:
    matchLabels:
      app: whoami
  template:
    metadata:
      labels:
        app: whoami
    spec:
      containers:
      - name: whoami
        image: traefik/whoami:latest
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: whoami
  namespace: ${NAMESPACE_APP}
spec:
  ports:
  - name: http
    port: 80
    targetPort: 80
  selector:
    app: whoami
EOF

# 4. Ingress-Route für Whoami erstellen
echo "🌐 Erstelle Ingress-Ressource für die Domain: ${DOMAIN}..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: whoami-ingress
  namespace: ${NAMESPACE_APP}
  annotations:
    kubernetes.io/ingress.class: traefik
spec:
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: whoami
            port:
              number: 80
EOF

echo "✅ Bereitstellung abgeschlossen!"
echo "--------------------------------------------------------"
echo "🌐 Du kannst die Anwendung bald unter folgender URL aufrufen:"
echo "http://${DOMAIN}"
echo "--------------------------------------------------------"
echo "💡 Hinweis: Wenn du auf Minikube oder Kind testest, stelle sicher,"
echo "dass der LoadBalancer-Dienst erreichbar ist (z.B. via 'minikube tunnel')."
