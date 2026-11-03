#!/usr/bin/env bash
set -euo pipefail

# Deploy an internal, unauthenticated registry with persistent storage.
# Requires kubectl, cluster access, and a default StorageClass.
NAMESPACE="${NAMESPACE:-registry}"
STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:3.1.2}"

command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }
[[ "$NAMESPACE" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && ${#NAMESPACE} -le 63 ]] || {
	echo "Invalid namespace" >&2
	exit 1
}
[[ "$STORAGE_SIZE" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || {
	echo "STORAGE_SIZE must be a positive quantity such as 10Gi" >&2
	exit 1
}
[[ "$REGISTRY_IMAGE" =~ ^[a-zA-Z0-9][a-zA-Z0-9._:/@-]*$ ]] || {
	echo "Invalid registry image reference" >&2
	exit 1
}

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -n "$NAMESPACE" -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
	name: registry-data
spec:
	accessModes:
		- ReadWriteOnce
	resources:
		requests:
			storage: ${STORAGE_SIZE}
---
apiVersion: apps/v1
kind: Deployment
metadata:
	name: registry
spec:
	replicas: 1
	strategy:
		type: Recreate
	selector:
		matchLabels:
			app: registry
	template:
		metadata:
			labels:
				app: registry
		spec:
			containers:
				- name: registry
					image: ${REGISTRY_IMAGE}
					ports:
						- name: http
							containerPort: 5000
					env:
						- name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
							value: /var/lib/registry
					volumeMounts:
						- name: data
							mountPath: /var/lib/registry
					readinessProbe:
						httpGet:
							path: /v2/
							port: http
						initialDelaySeconds: 5
						periodSeconds: 5
					livenessProbe:
						httpGet:
							path: /v2/
							port: http
						initialDelaySeconds: 15
						periodSeconds: 10
					resources:
						requests:
							cpu: 100m
							memory: 128Mi
						limits:
							cpu: "1"
							memory: 512Mi
			volumes:
				- name: data
					persistentVolumeClaim:
						claimName: registry-data
---
apiVersion: v1
kind: Service
metadata:
	name: registry
spec:
	type: ClusterIP
	selector:
		app: registry
	ports:
		- name: http
			port: 5000
			targetPort: http
EOF

kubectl rollout status deployment/registry -n "$NAMESPACE" --timeout=180s
printf '\nRegistry endpoint: registry.%s.svc.cluster.local:5000\n' "$NAMESPACE"
printf 'Local access: kubectl -n %s port-forward svc/registry 5000:5000\n' "$NAMESPACE"
echo 'Warning: HTTP only, without authentication. Configure TLS and authentication before production use.'
echo 'Cluster container runtimes need a reachable endpoint and appropriate TLS/HTTP configuration to pull images.'
