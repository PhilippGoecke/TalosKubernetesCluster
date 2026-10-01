#!/usr/bin/env bash
#
# Obtain the SHA-256 value from the matching official Talos GitHub release:
# https://github.com/siderolabs/talos/releases
#
# Example:
#   TALOSCTL_VERSION=v1.14.2 \
#   TALOSCTL_SHA256=c6c9552b0e5f767352c595fa1c0af4f186f697488646872955057d23990a66c4 \
#   ./install-talosctl-debian.bash
#
# Optional:
#   TALOSCTL_INSTALL_DIR="$HOME/.local/bin" ./install-talosctl-debian.bash
#
set -euo pipefail
IFS=$'\n\t'
umask 077

readonly TALOSCTL_VERSION="${TALOSCTL_VERSION:-v1.14.2}"
readonly TALOSCTL_SHA256="${TALOSCTL_SHA256:-c6c9552b0e5f767352c595fa1c0af4f186f697488646872955057d23990a66c4}"
readonly TALOSCTL_INSTALL_DIR="${TALOSCTL_INSTALL_DIR:-/usr/local/bin}"
readonly DOWNLOAD_BASE_URL="https://github.com/siderolabs/talos/releases/download"

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  local exit_code=$?
  if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
  exit "${exit_code}"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

case "${TALOSCTL_VERSION}" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) die "Set TALOSCTL_VERSION to a specific release tag, for example v1.10.0." ;;
esac

[[ "${TALOSCTL_SHA256}" =~ ^[[:xdigit:]]{64}$ ]] ||
  die "Set TALOSCTL_SHA256 to the 64-character SHA-256 checksum for the selected release."

case "$(uname -s)" in
  Linux) ;;
  *) die "This installer supports Debian/Linux only." ;;
esac

case "$(uname -m)" in
  x86_64) readonly ARCH="amd64" ;;
  aarch64 | arm64) readonly ARCH="arm64" ;;
  *) die "Unsupported CPU architecture: $(uname -m). Supported: x86_64, aarch64." ;;
esac

require_command curl
require_command sha256sum
require_command install
require_command mktemp

readonly ASSET_NAME="talosctl-linux-${ARCH}"
readonly DOWNLOAD_URL="${DOWNLOAD_BASE_URL}/${TALOSCTL_VERSION}/${ASSET_NAME}"
readonly TEMP_DIR="$(mktemp -d)"
readonly DOWNLOADED_BINARY="${TEMP_DIR}/${ASSET_NAME}"
readonly STAGED_BINARY="${TEMP_DIR}/talosctl"

trap cleanup EXIT HUP INT TERM

printf 'Downloading talosctl %s for linux-%s...\n' "${TALOSCTL_VERSION}" "${ARCH}"
curl \
  --fail \
  --location \
  --proto '=https' \
  --tlsv1.2 \
  --silent \
  --show-error \
  --retry 3 \
  --retry-delay 2 \
  --output "${DOWNLOADED_BINARY}" \
  "${DOWNLOAD_URL}"

printf '%s  %s\n' "${TALOSCTL_SHA256,,}" "${DOWNLOADED_BINARY}" | sha256sum --check --status ||
  die "Checksum verification failed; the binary was not installed."

# Confirm that the verified artifact is an ELF executable, not an error page.
file_output="$(file -b "${DOWNLOADED_BINARY}" 2>/dev/null || true)"
[[ "${file_output}" == *"ELF"* ]] ||
  die "The verified download is not a Linux ELF executable."

install_parent() {
  if [[ -w "${TALOSCTL_INSTALL_DIR}" ]]; then
    mkdir -p -- "${TALOSCTL_INSTALL_DIR}"
    install -m 0755 -- "${STAGED_BINARY}" "${TALOSCTL_INSTALL_DIR}/talosctl"
  else
    command -v sudo >/dev/null 2>&1 ||
      die "Write access to ${TALOSCTL_INSTALL_DIR} requires sudo, but sudo is unavailable."
    sudo mkdir -p -- "${TALOSCTL_INSTALL_DIR}"
    sudo install -m 0755 -- "${STAGED_BINARY}" "${TALOSCTL_INSTALL_DIR}/talosctl"
  fi
}

cp -- "${DOWNLOADED_BINARY}" "${STAGED_BINARY}"
chmod 0755 -- "${STAGED_BINARY}"

printf 'Installing verified talosctl to %s/talosctl...\n' "${TALOSCTL_INSTALL_DIR}"
install_parent

printf 'talosctl %s installed successfully.\n' "${TALOSCTL_VERSION}"
printf 'Verify with: %s/talosctl version --client\n' "${TALOSCTL_INSTALL_DIR}"
