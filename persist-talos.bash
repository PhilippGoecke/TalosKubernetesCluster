#!/usr/bin/env bash
# Example: IP=192.0.2.10 TALOS_CONFIG_FILE=./controlplane.yaml TALOSCONFIG=./talosconfig bash persist-talos.bash

# Requires Bash 4+ (for mapfile), jq, talosctl, and an interactive terminal.
set -o pipefail

log() {
    printf '%s\n' "$*"
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

(( BASH_VERSINFO[0] >= 4 )) || fail "Bash 4 or later is required."
command -v jq >/dev/null 2>&1 || fail "jq is required."
command -v talosctl >/dev/null 2>&1 || fail "talosctl is required."
[[ -t 0 ]] || fail "An interactive terminal is required for disk selection."

# Supply a complete machine configuration and its matching client credentials.
[[ -n "${IP:-}" ]] || fail "IP must be set."
[[ -f "${TALOS_CONFIG_FILE:-}" && -r "${TALOS_CONFIG_FILE:-}" ]] || fail "Set TALOS_CONFIG_FILE to a readable Talos machine configuration."
[[ -f "${TALOSCONFIG:-}" && -r "${TALOSCONFIG:-}" ]] || fail "Set TALOSCONFIG to the matching readable talosconfig client credentials."
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-600}"
[[ "${WAIT_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]{0,8}$ ]] || fail "WAIT_TIMEOUT_SECONDS must be a positive integer of at most 9 digits."

log "🔎 Checking that ${IP} is in maintenance mode before persisting Talos to disk..."
CURRENT_STAGE="$(
    set -o pipefail
    talosctl get machinestatus --insecure --nodes "${IP}" --output json 2>/dev/null |
        jq -rs '.[0].spec.stage // empty'
)" || fail "Unable to query machine status for ${IP}."
if [[ -z "${CURRENT_STAGE}" ]]; then
    fail "Unable to determine machine stage for ${IP}. Is it reachable and running Talos in maintenance mode?"
fi
if [[ "${CURRENT_STAGE}" != "maintenance" ]]; then
    fail "${IP} is in stage '${CURRENT_STAGE}', expected 'maintenance'. Refusing to install to avoid overwriting a running system."
fi
log "✅ ${IP} is in maintenance mode."

    log "💽 Available disks on ${IP}:"
    DISK_OUTPUT="$(
        set -o pipefail
        talosctl get disks --insecure --nodes "${IP}" --output json |
            jq -rs '[.[] | select(
                (.spec.dev_path | type == "string") and
                (.spec.dev_path | startswith("/dev/")) and
                (.spec.read_only // false | not) and
                (.spec.removable // false | not)
            )] | .[] | "\(.spec.dev_path)\t\(.spec.size // "unknown size")\t\(.spec.model // "unknown model")"'
    )" || fail "Unable to query disks for ${IP}."
    [[ -n "${DISK_OUTPUT}" ]] || fail "No writable, non-removable disk was found on ${IP}."
    mapfile -t DISK_LINES <<<"${DISK_OUTPUT}"

    printf '%s\n' "#  DEV_PATH        SIZE            MODEL"
    for i in "${!DISK_LINES[@]}"; do
        IFS=$'\t' read -r DEV_PATH SIZE MODEL <<<"${DISK_LINES[$i]}"
        printf '%d) %-15s %-15s %s\n' "$((i + 1))" "${DEV_PATH}" "${SIZE}" "${MODEL}"
    done

    while true; do
        read -rp "Select the disk number to install Talos on ${IP}: " DISK_CHOICE || fail "Disk selection cancelled."
        # Compare strings before using the selection in arithmetic.
        for i in "${!DISK_LINES[@]}"; do
            if [[ "${DISK_CHOICE}" == "$((i + 1))" ]]; then
                break 2
            fi
        done
        echo "Invalid selection, please enter a number between 1 and ${#DISK_LINES[@]}."
    done

    IFS=$'\t' read -r TALOS_INSTALL_DISK _ _ <<<"${DISK_LINES[$((DISK_CHOICE - 1))]}"
    [[ -n "${TALOS_INSTALL_DISK}" ]] || fail "No writable, non-removable disk was selected on ${IP}."

    log "⚠️ All data on ${TALOS_INSTALL_DISK} at ${IP} will be destroyed."
    read -rp "Type '${TALOS_INSTALL_DISK}' to confirm installation: " CONFIRM_DISK || fail "Installation cancelled."
    [[ "${CONFIRM_DISK}" == "${TALOS_INSTALL_DISK}" ]] || fail "Installation cancelled."

    # Applying a machine configuration in maintenance mode triggers installation.
    # Clear any selector so the explicitly selected disk is used.
    INSTALL_PATCH="$(jq -n --arg disk "${TALOS_INSTALL_DISK}" \
        '{machine: {install: {disk: $disk, diskSelector: null}}}')" || fail "Unable to create installation patch."
    log "💾 Installing Talos on ${IP} to selected disk ${TALOS_INSTALL_DISK}..."
    talosctl apply-config \
        --insecure \
        --nodes "${IP}" \
        --file "${TALOS_CONFIG_FILE}" \
        --config-patch "${INSTALL_PATCH}" \
        --mode auto || fail "Failed to apply the machine configuration to ${IP}."

    # The API requires authentication once configured. Do not rely on observing
    # a brief disconnect during reboot, which polling can miss.
    log "⏳ Waiting for ${IP} to reach the running stage after installation..."
    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while true; do
        if (( SECONDS >= WAIT_DEADLINE )); then
            fail "Timed out waiting for ${IP} to reach the running stage. Check installation logs and TALOSCONFIG credentials."
        fi
        if CURRENT_STAGE="$(
            set -o pipefail
            talosctl --talosconfig "${TALOSCONFIG}" get machinestatus \
                --endpoints "${IP}" --nodes "${IP}" --output json 2>/dev/null |
                jq -rs '.[0].spec.stage // empty'
        )" && [[ "${CURRENT_STAGE}" == "running" ]]; then
            break
        fi
        sleep 2
    done
    log "✅ ${IP} has reached the running stage."
