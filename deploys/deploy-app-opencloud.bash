#!/usr/bin/env bash
# Deploy OpenCloud with persistent configuration and data.
# Requires kubectl, an active cluster context, and a default StorageClass.
# Local access: ./deploy.sh
# TLS ingress (requires an ingress controller and an existing TLS Secret):
# OPENCloud_URL is not used; set OPENCLOUD_URL as shown below.
# OPENCLOUD_URL=https://cloud.example.com INGRESS_HOST=cloud.example.com \
#   TLS_SECRET=cloud-tls INGRESS_CLASS=nginx ./deploy.sh
# Set IMAGE to a tested, pinned image version for production.
set -euo pipefail

NAMESPACE="${NAMESPACE:-opencloud}"
IMAGE="${IMAGE:-opencloudeu/opencloud:latest}"
OPENCLOUD_URL="${OPENCLOUD_URL:-http://localhost:9200}"
STORAGE_SIZE="${STORAGE_SIZE:-10Gi}"
INGRESS_HOST="${INGRESS_HOST:-}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
TLS_SECRET="${TLS_SECRET:-}"

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
dns_name() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; }
command -v kubectl >/dev/null || die 'kubectl is required.'
dns_name "$NAMESPACE" && [[ "$NAMESPACE" != *.* && ${#NAMESPACE} -le 63 ]] || die 'Invalid namespace.'
[[ "$IMAGE" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || die 'Invalid image.'
[[ "$STORAGE_SIZE" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]] || die 'Invalid storage size.'
[[ "$OPENCLOUD_URL" =~ ^https?://[a-zA-Z0-9.-]+(:[0-9]+)?$ ]] || die 'URL must be an HTTP(S) origin without a trailing slash.'
if [[ -n "$INGRESS_HOST" ]]; then
	dns_name "$INGRESS_HOST" && dns_name "$INGRESS_CLASS" && dns_name "$TLS_SECRET" || die 'Invalid ingress settings; TLS_SECRET is required.'
	[[ "$OPENCLOUD_URL" == "https://$INGRESS_HOST" ]] || die 'Ingress requires OPENCLOUD_URL=https://INGRESS_HOST.'
fi

kubectl cluster-info >/dev/null
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
k() { kubectl -n "$NAMESPACE" "$@"; }

# Keep the original administrator password across subsequent deployments.
if ! kubectl get secret opencloud-admin >/dev/null 2>&1; then
	command -v openssl >/dev/null || die 'openssl is required to generate the initial password.'
	password="${ADMIN_PASSWORD:-$(openssl rand -hex 24)}"
	# Pass the password through stdin rather than exposing it in process arguments.
	printf '%s' "$password" | kubectl create secret generic opencloud-admin --from-file=password=/dev/stdin
	unset password
fi

for claim in opencloud-config opencloud-data; do
	cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
	name: ${claim}
spec:
	accessModes: [ReadWriteOnce]
	resources:
		requests:
			storage: ${STORAGE_SIZE}
EOF
done

cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
	name: opencloud
spec:
	replicas: 1
	strategy:
		type: Recreate
	selector:
		matchLabels:
			app: opencloud
	template:
		metadata:
			labels:
				app: opencloud
		spec:
			securityContext:
				runAsUser: 1000
				runAsGroup: 1000
				fsGroup: 1000
			initContainers:
				- name: initialize
					image: ${IMAGE}
					command: [/bin/sh, -ec]
					args:
						- 'if [ ! -s /etc/opencloud/opencloud.yaml ]; then opencloud init --insecure; fi'
					env:
						- name: IDM_ADMIN_PASSWORD
							valueFrom:
								secretKeyRef:
									name: opencloud-admin
									key: password
					volumeMounts:
						- name: config
							mountPath: /etc/opencloud
						- name: data
							mountPath: /var/lib/opencloud
			containers:
				- name: opencloud
					image: ${IMAGE}
					command: [opencloud, server]
					env:
						- name: OC_URL
							value: '${OPENCLOUD_URL}'
						# HTTP is restricted to the cluster or localhost port-forward.
						# Terminate public TLS at the ingress controller.
						- name: PROXY_TLS
							value: 'false'
						- name: OC_INSECURE
							value: 'true'
						- name: PROXY_HTTP_ADDR
							value: '0.0.0.0:9200'
					ports:
						- name: http
							containerPort: 9200
					startupProbe:
						tcpSocket:
							port: http
						periodSeconds: 5
						failureThreshold: 60
					readinessProbe:
						tcpSocket:
							port: http
						periodSeconds: 10
					resources:
						requests:
							cpu: 250m
							memory: 512Mi
					volumeMounts:
						- name: config
							mountPath: /etc/opencloud
						- name: data
							mountPath: /var/lib/opencloud
			volumes:
				- name: config
					persistentVolumeClaim:
						claimName: opencloud-config
				- name: data
					persistentVolumeClaim:
						claimName: opencloud-data
---
apiVersion: v1
kind: Service
metadata:
	name: opencloud
spec:
	selector:
		app: opencloud
	ports:
		- name: http
			port: 9200
			targetPort: http
EOF

if [[ -n "$INGRESS_HOST" ]]; then
	kubectl get secret "$TLS_SECRET" >/dev/null
	cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
	name: opencloud
spec:
	ingressClassName: ${INGRESS_CLASS}
	tls:
		- hosts: ['${INGRESS_HOST}']
			secretName: ${TLS_SECRET}
	rules:
		- host: ${INGRESS_HOST}
			http:
				paths:
					- path: /
						pathType: Prefix
						backend:
							service:
								name: opencloud
								port:
									name: http
EOF
fi

kubectl rollout status deployment/opencloud --timeout=300s
printf '\nOpenCloud URL: %s\nUsername: admin\n' "$OPENCLOUD_URL"
printf 'Retrieve the initial password (may differ if changed in OpenCloud):\n'
printf "kubectl -n %s get secret opencloud-admin -o jsonpath='{.data.password}' | base64 --decode; echo\n" "$NAMESPACE"
if [[ -z "$INGRESS_HOST" ]]; then
	printf '\nStart local access with:\nkubectl -n %s port-forward --address=127.0.0.1 service/opencloud 9200:9200\n' "$NAMESPACE"
fi
