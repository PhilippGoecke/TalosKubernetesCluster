#!/usr/bin/env bash
# Deploy Vaultwarden with persistent SQLite storage.
# Local access: ./deploy.sh
# HTTPS ingress (TLS secret must already exist in the namespace):
# DOMAIN=https://vault.example.com TLS_SECRET_NAME=vaultwarden-tls ./deploy.sh
# Optional: ADMIN_TOKEN, IMAGE, STORAGE_CLASS, STORAGE_SIZE, INGRESS_CLASS.
# Pin IMAGE to a tested tag or digest for production. Back up /data regularly.
set -Eeuo pipefail

NAMESPACE="${NAMESPACE:-vaultwarden}"
DOMAIN="${DOMAIN:-http://localhost:8080}"
DOMAIN="${DOMAIN%/}"
IMAGE="${IMAGE:-vaultwarden/server:latest}"
STORAGE_SIZE="${STORAGE_SIZE:-5Gi}"
STORAGE_CLASS="${STORAGE_CLASS:-}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_SECRET_NAME="${TLS_SECRET_NAME:-}"

command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
kubectl cluster-info >/dev/null

if [[ "$DOMAIN" != 'http://localhost:8080' ]]; then
  if [[ ! "$DOMAIN" =~ ^https://[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
    echo 'DOMAIN must be https://hostname (no path or port).' >&2
    exit 1
  fi
  : "${TLS_SECRET_NAME:?Set TLS_SECRET_NAME to an existing Kubernetes TLS secret}"
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ "$DOMAIN" == https://* ]]; then
  kubectl -n "$NAMESPACE" get secret "$TLS_SECRET_NAME" >/dev/null
fi

# Omit ADMIN_TOKEN to leave the admin interface disabled on a new installation.
# An existing admin secret is retained on subsequent deployments.
# Supply a strong token or a Vaultwarden-generated Argon2 hash; never commit it.
if [[ -n "${ADMIN_TOKEN:-}" ]]; then
  # Stream the token rather than exposing it in kubectl's command-line arguments.
  printf '%s' "$ADMIN_TOKEN" |
    kubectl -n "$NAMESPACE" create secret generic vaultwarden-admin \
      --from-file=ADMIN_TOKEN=/dev/stdin --dry-run=client -o yaml |
    kubectl apply --server-side --field-manager=vaultwarden-deploy -f -
fi

kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: vaultwarden-data
spec:
  accessModes: [ReadWriteOnce]
${STORAGE_CLASS:+  storageClassName: "$STORAGE_CLASS"}
  resources:
    requests:
      storage: "$STORAGE_SIZE"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vaultwarden
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: vaultwarden
  template:
    metadata:
      labels:
        app: vaultwarden
    spec:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: vaultwarden
          image: "$IMAGE"
          imagePullPolicy: Always
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: [ALL]
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: DOMAIN
              value: "$DOMAIN"
            - name: ROCKET_PORT
              value: "8080"
            - name: SIGNUPS_ALLOWED
              value: "false"
            - name: INVITATIONS_ALLOWED
              value: "false"
            - name: ADMIN_TOKEN
              valueFrom:
                secretKeyRef:
                  name: vaultwarden-admin
                  key: ADMIN_TOKEN
                  optional: true
          volumeMounts:
            - name: data
              mountPath: /data
          readinessProbe:
            httpGet:
              path: /alive
              port: http
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /alive
              port: http
            periodSeconds: 30
          startupProbe:
            httpGet:
              path: /alive
              port: http
            periodSeconds: 5
            failureThreshold: 60
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              memory: 512Mi
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: vaultwarden-data
---
apiVersion: v1
kind: Service
metadata:
  name: vaultwarden
spec:
  selector:
    app: vaultwarden
  ports:
    - name: http
      port: 80
      targetPort: http
EOF

# Requires an installed ingress controller; modern controllers proxy WebSockets.
if [[ "$DOMAIN" == https://* ]]; then
  HOST="${DOMAIN#https://}"
  kubectl -n "$NAMESPACE" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: vaultwarden
spec:
  ingressClassName: "$INGRESS_CLASS"
  tls:
    - hosts: ["$HOST"]
      secretName: "$TLS_SECRET_NAME"
  rules:
    - host: "$HOST"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: vaultwarden
                port:
                  number: 80
EOF
fi

kubectl -n "$NAMESPACE" rollout status deployment/vaultwarden --timeout=300s
printf 'Vaultwarden deployed: %s\n' "$DOMAIN"
if [[ "$DOMAIN" == 'http://localhost:8080' ]]; then
  printf 'Local access: kubectl -n %q port-forward service/vaultwarden 8080:80\n' "$NAMESPACE"
else
  echo 'Point the hostname at your ingress controller and verify its TLS certificate.'
fi
echo 'Registration is disabled. Set ADMIN_TOKEN, then use /admin to invite users.'
