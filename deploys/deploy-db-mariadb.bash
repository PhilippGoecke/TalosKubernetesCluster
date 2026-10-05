#!/bin/bash
# ==============================================================================
# Production-Ready MariaDB Operator Deployment Script for Kubernetes
# ==============================================================================
# Dieses Skript automatisiert die Installation von cert-manager, dem official
# mariadb-operator und provisioniert ein hochverfügbares Galera Cluster.
# ==============================================================================

set -euo pipefail

# --- Konfigurations-Variablen ---
NAMESPACE="database"
OPERATOR_VERSION="0.30.0" 
RELEASE_NAME="mariadb-operator"
CLUSTER_NAME="mariadb-galera-prod"
STORAGE_CLASS="standard"   # Ändern Sie dies in Ihre performante CSI (z.B. gp3, premium-rwo)
STORAGE_SIZE="50Gi"
ROOT_DB_PASS=$(openssl rand -base64 24)
USER_DB_PASS=$(openssl rand -base64 24)

log_info() { echo -e "\033[0;34m[INFO]\033[0m $1"; }
log_success() { echo -e "\033[0;32m[SUCCESS]\033[0m $1"; }
log_warn() { echo -e "\033[0;33m[WARNUNG]\033[0m $1"; }

# --- Schritt 1: Core Prerequisite - Cert Manager ---
log_info "Schritt 1: Prüfe und installiere cert-manager (notwendig für Webhook-TLS)..."
if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    log_info "Installiere cert-manager via offizieller Manifeste..."
    kubectl apply -f https://github.com
    log_info "Warte auf die Betriebsbereitschaft von cert-manager..."
    kubectl wait --namespace cert-manager --for=condition=ready pod --all --timeout=120s
else
    log_success "cert-manager ist bereits installiert."
fi

# --- Schritt 2: Namespace initialisieren ---
log_info "Schritt 2: Erstelle dedizierten Namespace: '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# --- Schritt 3: Helm Repository registrieren ---
log_info "Schritt 3: Registriere das Helm-Repository für mariadb-operator..."
if ! helm repo list | grep -q "mariadb-operator"; then
    helm repo add mariadb-operator https://github.io
fi
helm repo update

# --- Schritt 4: MariaDB Operator installieren ---
log_info "Schritt 4: Installiere mariadb-operator v${OPERATOR_VERSION} via Helm..."
helm upgrade --install "${RELEASE_NAME}" mariadb-operator/mariadb-operator \
    --namespace "${NAMESPACE}" \
    --version "${OPERATOR_VERSION}" \
    --set ha.enabled=true \
    --set metrics.enabled=true \
    --wait

# --- Schritt 5: Produktions-Secrets erzeugen ---
log_info "Schritt 5: Erzeuge kryptografisch sichere Passwörter in K8s-Secrets..."
kubectl create secret generic mariadb-prod-credentials \
    --namespace "${NAMESPACE}" \
    --from-literal=root-password="${ROOT_DB_PASS}" \
    --from-literal=password="${USER_DB_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f -

# --- Schritt 6: High-Availability Cluster deployen ---
log_info "Schritt 6: Erzeuge das HA Galera Multi-Master MariaDB Cluster..."
cat <<EOF | kubectl apply -f -
apiVersion: mariadb.mmontes.io/v1alpha1
kind: MariaDB
metadata:
  name: ${CLUSTER_NAME}
  namespace: ${NAMESPACE}
spec:
  rootPasswordSecretKeyRef:
    name: mariadb-prod-credentials
    key: root-password

  # Datenbank-Initialisierung
  database: app_production
  username: app_user
  passwordSecretKeyRef:
    name: mariadb-prod-credentials
    key: password

  # Topologie: Hochverfügbares Galera Multi-Master Setup (3 Instanzen)
  replicas: 3
  galera:
    enabled: true
    sst: mariabackup
    availableWhenInitializing: false
    # Verhindert, dass DB-Instanzen auf demselben physikalischen Node laufen (Ausfallsicherheit)
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/instance
              operator: In
              values:
              - ${CLUSTER_NAME}
          topologyKey: "kubernetes.io/hostname"

  # Persistenter Cloud-Speicher
  storage:
    size: ${STORAGE_SIZE}
    storageClassName: ${STORAGE_CLASS}
    volumeClaimTemplate:
      accessModes: [ "ReadWriteOnce" ]
      resources:
        requests:
          storage: ${STORAGE_SIZE}

  # Produktions-Ressourcengarantien (Verhindert Noisy-Neighbor-Effekte)
  resources:
    requests:
      cpu: "1"
      memory: "2Gi"
    limits:
      cpu: "2"
      memory: "4Gi"

  # Integriertes Performance Monitoring (Prometheus Metrics Exporter)
  metrics:
    enabled: true
EOF

log_success "MariaDB Multi-Master Cluster erfolgreich übermittelt!"
log_info "------------------------------------------------------------------------"
log_info "Deployment-Überwachung:"
log_info "Status abrufen:  kubectl get mariadb -n ${NAMESPACE}"
log_info "Pods beobachten: kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/instance=${CLUSTER_NAME} -w"
log_info "------------------------------------------------------------------------"
log_warn "SICHERN SIE DIESE AUTOMATISCH GENERIERTEN DB-PASSWÖRTER:"
echo "Root-Passwort:     $ROOT_DB_PASS"
echo "App-User-Passwort: $USER_DB_PASS"
log_info "------------------------------------------------------------------------"
