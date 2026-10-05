#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

# --- CONFIGURATION VARIABLES ---
NAMESPACE="excalidraw"
APP_NAME="excalidraw"
COLLAB_NAME="excalidraw-collab"
# Change this to your actual target domain name
DOMAIN_NAME="://example.com" 

echo "==== Starting Excalidraw Deployment on Kubernetes ===="

# 1. Create the Namespace
echo "Creating namespace: ${NAMESPACE}..."
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# 2. Deploy Excalidraw Collaboration Server
echo "Deploying Collaboration Backend Server..."
cat <<EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${COLLAB_NAME}
  labels:
    app: ${COLLAB_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${COLLAB_NAME}
  template:
    metadata:
      labels:
        app: ${COLLAB_NAME}
    spec:
      containers:
      - name: collab-server
        image: pmoscode/excalidraw-collab-server:1.0.0
        ports:
        - containerPort: 3002
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: ${COLLAB_NAME}
spec:
  ports:
  - port: 3002
    targetPort: 3002
  selector:
    app: ${COLLAB_NAME}
EOF

# 3. Deploy Excalidraw Frontend
echo "Deploying Frontend Server..."
cat <<EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}
  labels:
    app: ${APP_NAME}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
    spec:
      containers:
      - name: frontend
        image: pmoscode/excalidraw:latest
        ports:
        - containerPort: 80
        env:
        # Dynamically configures the collaboration URL for the user's browser
        - name: BACKEND_VITE_APP_WS_SERVER_URL
          value: "https://${DOMAIN_NAME}/socket.io"
        resources:
          limits:
            cpu: "500m"
            memory: "512Mi"
          requests:
            cpu: "100m"
            memory: "128Mi"
---
apiVersion: v1
kind: Service
metadata:
  name: ${APP_NAME}
spec:
  ports:
  - port: 80
    targetPort: 80
  selector:
    app: ${APP_NAME}
EOF

# 4. Deploy the Ingress Controller (Routing traffic to frontend vs backend websocket)
echo "Deploying Ingress Routing..."
cat <<EOF | kubectl apply -n ${NAMESPACE} -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${APP_NAME}-ingress
  annotations:
    kubernetes.io/ingress.class: nginx
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    # Essential for websocket traffic required by real-time collaboration
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  rules:
  - host: ${DOMAIN_NAME}
    http:
      paths:
      # WebSocket routing for live rooms
      - path: /socket.io
        pathType: Prefix
        backend:
          service:
            name: ${COLLAB_NAME}
            port:
              number: 3002
      # Frontend interface routing
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${APP_NAME}
            port:
              number: 80
EOF

# 5. Check Deployment Status
echo "Waiting for pods to be ready..."
kubectl rollout status deployment/${APP_NAME} -n ${NAMESPACE}
kubectl rollout status deployment/${COLLAB_NAME} -n ${NAMESPACE}

echo "==== Deployment Completed Successfully ===="
echo "Make sure your DNS records point '${DOMAIN_NAME}' to your cluster Ingress Controller IP."
