#!/usr/bin/env bash

# Fehlerbehandlung: Skript stoppt bei Fehlern
set -euo pipefail

# --- KONFIGURATION ---
NAMESPACE="paperless"
STORAGE_CLASS="standard" # Ändern Sie dies in Ihre K8s StorageClass (z.B. longhorn, local-path)
ADMIN_USER="admin"
ADMIN_PASSWORD="SuperSecurePassword123"
ADMIN_EMAIL="admin@example.local"

echo "🚀 Starte Paperless-ngx Deployment auf Kubernetes..."

# 1. Namespace erstellen
echo "📦 Erstelle Namespace: ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 2. Storage & Secrets anwenden
echo "💾 Erstelle Storage-Konfigurationen und Secrets..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-data-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-media-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: 30Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: paperless-consume-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pgdata-pvc
spec:
  accessModes: [ "ReadWriteOnce" ]
  storageClassName: "${STORAGE_CLASS}"
  resources:
    requests:
      storage: 5Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: paperless-secrets
type: Opaque
stringData:
  DB_PASS: "paperlessDBpass"
  PAPERLESS_SECRET_KEY: "3k1n4-changes-this-to-something-random-and-secure"
EOF

# 3. Redis Deployment (Broker)
echo "🧠 Erstelle Redis Service..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless-redis
  template:
    metadata:
      labels:
        app: paperless-redis
    spec:
      containers:
      - name: redis
        image: docker.io/library/redis:7-alpine
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-redis
spec:
  ports:
  - port: 6379
  selector:
    app: paperless-redis
EOF

# 4. PostgreSQL Deployment (Datenbank)
echo "🗄️ Erstelle PostgreSQL Datenbank..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-db
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless-db
  template:
    metadata:
      labels:
        app: paperless-db
    spec:
      containers:
      - name: db
        image: docker.io/library/postgres:16-alpine
        env:
        - name: POSTGRES_DB
          value: "paperless"
        - name: POSTGRES_USER
          value: "paperless"
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: paperless-secrets
              key: DB_PASS
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: db-data
          mountPath: /var/lib/postgresql/data
      volumes:
      - name: db-data
          persistentVolumeClaim:
            claimName: pgdata-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-db
spec:
  ports:
  - port: 5432
  selector:
    app: paperless-db
EOF

# Warten, bis die DB bereit ist
echo "⏳ Warte auf die Datenbank..."
kubectl rollout status deployment/paperless-db -n ${NAMESPACE} --timeout=60s

# 5. Paperless-ngx App Deployment
echo "📄 Erstelle Paperless-ngx App-Deployment..."
kubectl apply -n ${NAMESPACE} -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: paperless-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: paperless-web
  template:
    metadata:
      labels:
        app: paperless-web
    spec:
      containers:
      - name: webserver
        image: ghcr.io/paperless-ngx/paperless-ngx:latest
        ports:
        - containerPort: 8000
        env:
        - name: PAPERLESS_REDIS
          value: "redis://paperless-redis:6379"
        - name: PAPERLESS_DBENGINE
          value: "postgresql"
        - name: PAPERLESS_DBHOST
          value: "paperless-db"
        - name: PAPERLESS_DBUSER
          value: "paperless"
        - name: PAPERLESS_DBNAME
          value: "paperless"
        - name: PAPERLESS_DBPASS
          valueFrom:
            secretKeyRef:
              name: paperless-secrets
              key: DB_PASS
        - name: PAPERLESS_SECRET_KEY
          valueFrom:
            secretKeyRef:
              name: paperless-secrets
              key: PAPERLESS_SECRET_KEY
        # Admin Initialisierung via Env-Variablen
        - name: PAPERLESS_ADMIN_USER
          value: "${ADMIN_USER}"
        - name: PAPERLESS_ADMIN_PASSWORD
          value: "${ADMIN_PASSWORD}"
        - name: PAPERLESS_ADMIN_EMAIL
          value: "${ADMIN_EMAIL}"
        - name: PAPERLESS_TIME_ZONE
          value: "Europe/Berlin"
        - name: PAPERLESS_OCR_LANGUAGE
          value: "deu+eng"
        volumeMounts:
        - name: data
          mountPath: /usr/src/paperless/data
        - name: media
          mountPath: /usr/src/paperless/media
        - name: consume
          mountPath: /usr/src/paperless/consume
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: paperless-data-pvc
      - name: media
        persistentVolumeClaim:
          claimName: paperless-media-pvc
      - name: consume
        persistentVolumeClaim:
          claimName: paperless-consume-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: paperless-web
spec:
  type: ClusterIP
  ports:
  - port: 8000
    targetPort: 8000
  selector:
    app: paperless-web
EOF

# Warten auf Web-Pod Verfügbarkeit
echo "⏳ Warte auf Fertigstellung des Deployments (das kann einen Moment dauern)..."
kubectl rollout status deployment/paperless-web -n ${NAMESPACE} --timeout=120s

echo "🎉 Deployment erfolgreich abgeschlossen!"
echo "--------------------------------------------------------"
echo "Der Admin-Nutzer '${ADMIN_USER}' wurde automatisch angelegt."
echo "Nutzen Sie 'kubectl port-forward svc/paperless-web 8000:8000 -n ${NAMESPACE}'"
echo "um lokal über http://localhost:8000 auf Paperless zuzugreifen."
echo "--------------------------------------------------------"
