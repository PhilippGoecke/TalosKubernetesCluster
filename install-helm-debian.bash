#!/usr/bin/env bash
#   ./install-helm-debian.bash

set -euo pipefail
IFS=$'\n\t'
umask 077

readonly HELM_BUILDKITE_APT_KEY_FINGERPRINT="DDF78C3E6EBB2D2CC223C95C62BA89D07698DBC6"
readonly HELM_GPG_KEY_URL="https://packages.buildkite.com/helm-linux/helm-debian/gpgkey"
readonly HELM_KEYRING_PATH="/usr/share/keyrings/helm.gpg"
readonly HELM_REPOSITORY_FILE="/etc/apt/sources.list.d/helm-stable-debian.list"
readonly HELM_REPOSITORY="deb [signed-by=${HELM_KEYRING_PATH}] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

if [[ "$(id -u)" -eq 0 ]]; then
  SUDO=()
else
  require_command sudo
  SUDO=(sudo)
  "${SUDO[@]}" -v
fi

require_command apt
require_command mktemp
require_command rm
require_command awk
require_command install

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/helm-install.XXXXXXXX")"
readonly TEMP_DIR
readonly DOWNLOADED_KEY="${TEMP_DIR}/helm-release-key.asc"
readonly DEARMORED_KEY="${TEMP_DIR}/helm.gpg"
readonly REPOSITORY_STAGING_FILE="${TEMP_DIR}/helm-stable-debian.list"

cleanup() {
  local status=$?
  rm -rf -- "${TEMP_DIR}"
  exit "${status}"
}
trap cleanup EXIT HUP INT TERM

printf 'Updating package index and installing repository prerequisites...\n'
"${SUDO[@]}" apt update
"${SUDO[@]}" apt install --yes --no-install-recommends \
  ca-certificates curl gpg apt-transport-https

require_command curl
require_command gpg

printf 'Downloading the Helm APT signing key over HTTPS...\n'
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --silent \
  --show-error \
  --retry 3 \
  --retry-delay 2 \
  --output "${DOWNLOADED_KEY}" \
  "${HELM_GPG_KEY_URL}"

downloaded_fingerprint="$(
  gpg --batch --quiet --show-keys --with-colons "${DOWNLOADED_KEY}" |
    awk -F: '$1 == "fpr" { print $10; exit }'
)"

[[ -n "${downloaded_fingerprint}" ]] ||
  die "The downloaded Helm signing key contains no fingerprint."

[[ "${downloaded_fingerprint}" == "${HELM_BUILDKITE_APT_KEY_FINGERPRINT}" ]] ||
  die "Unexpected Helm APT key fingerprint: potential key compromise."

# Convert the verified key locally before any privileged installation occurs.
gpg --batch --yes --dearmor \
  --output "${DEARMORED_KEY}" \
  "${DOWNLOADED_KEY}"

[[ -s "${DEARMORED_KEY}" ]] ||
  die "The verified signing key could not be converted to a keyring."

printf '%s\n' "${HELM_REPOSITORY}" >"${REPOSITORY_STAGING_FILE}"

printf 'Installing the verified Helm repository signing key...\n'
"${SUDO[@]}" install \
  --owner=root \
  --group=root \
  --mode=0644 \
  "${DEARMORED_KEY}" \
  "${HELM_KEYRING_PATH}"

printf 'Configuring the Helm APT repository...\n'
"${SUDO[@]}" install \
  --owner=root \
  --group=root \
  --mode=0644 \
  "${REPOSITORY_STAGING_FILE}" \
  "${HELM_REPOSITORY_FILE}"

printf 'Updating package index and installing Helm...\n'
"${SUDO[@]}" apt-get update
"${SUDO[@]}" apt-get install --yes helm

printf 'Helm installed successfully: %s\n' "$(/usr/bin/helm version --short 2>/dev/null || helm version --short)"
