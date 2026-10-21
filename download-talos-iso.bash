#!/usr/bin/env bash
set -Eeuo pipefail

TALOS_VERSION="${TALOS_VERSION:-v1.14.1}"
TALOS_SCHEMATIC_ID="${TALOS_SCHEMATIC_ID:-}"
STATE_DIRECTORY="${STATE_DIRECTORY:-${PWD}/downloads}"

readonly ISO_PATH="${STATE_DIRECTORY}/talos-${TALOS_VERSION}-amd64-custom.iso"

log() {
  printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
}

die() {
  log "ERROR: $*"
  exit 1
}

download_iso() {
  local schematic_id iso_url

  mkdir -p "${STATE_DIRECTORY}"
  if [[ ! -s "${ISO_PATH}" ]]; then
    schematic_id="${TALOS_SCHEMATIC_ID}"
    if [[ -z "${schematic_id}" ]]; then
      log "Creating Image Factory schematic with iscsi-tools and util-linux-tools"
      schematic_id=$(curl --fail --silent --show-error --retry 3 \
        --request POST \
        --header 'Content-Type: application/json' \
        --data '{"customization":{"systemExtensions":{"officialExtensions":["siderolabs/iscsi-tools","siderolabs/util-linux-tools"]}}}' \
        https://factory.talos.dev/schematics | jq --raw-output '.id')
      [[ -n "${schematic_id}" && "${schematic_id}" != "null" ]] || die "Image Factory did not return a schematic ID"
    fi
    iso_url="${TALOS_ISO_URL:-https://factory.talos.dev/image/${schematic_id}/${TALOS_VERSION}/metal-amd64.iso}"
    log "Downloading custom Talos ISO: ${iso_url}"
    curl --fail --location --retry 3 --output "${ISO_PATH}" "${iso_url}"
  else
    log "Using existing custom Talos ISO: ${ISO_PATH}"
  fi
}

download_iso
