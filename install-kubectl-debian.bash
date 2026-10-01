#!/usr/bin/env bash
#
# Usage:
#   ./install-kubectl-debian.bash
#   KUBERNETES_MINOR_VERSION=v1.37 ./install-kubectl-debian.sh

set -euo pipefail

KUBERNETES_MINOR_VERSION="${KUBERNETES_MINOR_VERSION:-v1.37}"
KEYRING_DIRECTORY="/etc/apt/keyrings"
KEYRING_PATH="${KEYRING_DIRECTORY}/kubernetes-apt-keyring.gpg"
REPOSITORY_FILE="/etc/apt/sources.list.d/kubernetes.list"
REPOSITORY_URL="https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR_VERSION}/deb/"
KEY_URL="${REPOSITORY_URL}Release.key"

if [[ ! "${KUBERNETES_MINOR_VERSION}" =~ ^v[0-9]+\.[0-9]+$ ]]; then
  echo "Error: KUBERNETES_MINOR_VERSION must use the format v<major>.<minor> (for example, v1.37)." >&2
  exit 1
fi

echo "Updating the APT package index..."
apt update

echo "Installing repository prerequisites..."
apt install -y apt-transport-https ca-certificates curl gnupg

echo "Installing the Kubernetes repository signing key..."
mkdir -p -m 755 "${KEYRING_DIRECTORY}"
curl -fsSL "${KEY_URL}" | gpg --dearmor --batch --yes -o "${KEYRING_PATH}"
chmod 644 "${KEYRING_PATH}"

echo "Configuring the Kubernetes ${KUBERNETES_MINOR_VERSION} APT repository..."
echo "deb [signed-by=${KEYRING_PATH}] ${REPOSITORY_URL} /" | tee "${REPOSITORY_FILE}" >/dev/null
chmod 644 "${REPOSITORY_FILE}"

echo "Updating the APT package index with the Kubernetes repository..."
apt update

echo "Installing kubectl..."
apt install -y kubectl

echo "kubectl installed successfully: $(kubectl version --client 2>/dev/null || kubectl version --client=true)"
