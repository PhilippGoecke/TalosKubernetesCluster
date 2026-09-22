
    log "🔎 Checking that ${IP} is in maintenance mode before persisting Talos to disk..."
    CURRENT_STAGE="$(
        talosctl get machinestatus --insecure --nodes "${IP}" --output json 2>/dev/null |
            jq -rs '.[0].spec.stage // empty'
    )"
    if [[ -z "${CURRENT_STAGE}" ]]; then
        fail "Unable to determine machine stage for ${IP}. Is it reachable and running Talos in maintenance mode?"
    fi
    if [[ "${CURRENT_STAGE}" != "maintenance" ]]; then
        fail "${IP} is in stage '${CURRENT_STAGE}', expected 'maintenance'. Refusing to install to avoid overwriting a running system."
    fi
    log "✅ ${IP} is in maintenance mode."

    log "💽 Available disks on ${IP}:"
    mapfile -t DISK_LINES < <(
        talosctl get disks --insecure --nodes "${IP}" --output json |
            jq -rs '[.[] | select(
                .spec.dev_path != null and
                (.spec.read_only // false | not) and
                (.spec.removable // false | not)
            )] | .[] | "\(.spec.dev_path)\t\(.spec.size // "unknown size")\t\(.spec.model // "unknown model")"'
    )
    [[ "${#DISK_LINES[@]}" -gt 0 ]] || fail "No writable, non-removable bootable disk was found on ${IP}."

    printf '%s\n' "#  DEV_PATH        SIZE            MODEL"
    for i in "${!DISK_LINES[@]}"; do
        IFS=$'\t' read -r DEV_PATH SIZE MODEL <<<"${DISK_LINES[$i]}"
        printf '%d) %-15s %-15s %s\n' "$((i + 1))" "${DEV_PATH}" "${SIZE}" "${MODEL}"
    done

    while true; do
        read -rp "Select the disk number to install Talos on ${IP}: " DISK_CHOICE
        if [[ "${DISK_CHOICE}" =~ ^[0-9]+$ ]] && (( DISK_CHOICE >= 1 && DISK_CHOICE <= ${#DISK_LINES[@]} )); then
            break
        fi
        echo "Invalid selection, please enter a number between 1 and ${#DISK_LINES[@]}."
    done

    IFS=$'\t' read -r TALOS_INSTALL_DISK _ _ <<<"${DISK_LINES[$((DISK_CHOICE - 1))]}"
    [[ -n "${TALOS_INSTALL_DISK}" ]] || fail "No writable, non-removable bootable disk was found on ${IP}."

    log "💾 Installing Talos on ${IP} to selected disk ${TALOS_INSTALL_DISK}..."
    log "⚠️ All data on ${TALOS_INSTALL_DISK} at ${IP} will be destroyed."
    talosctl install \
        --insecure \
        --nodes "${IP}" \
        --disk "${TALOS_INSTALL_DISK}"

    log "⏳ Waiting for ${IP} to reboot after Talos installation..."
    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while talosctl get machinestatus --insecure --nodes "${IP}" >/dev/null 2>&1; do
        if (( SECONDS >= WAIT_DEADLINE )); then
            fail "Timed out waiting for ${IP} to reboot after Talos installation."
        fi
        sleep 2
    done

    WAIT_DEADLINE=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    while ! talosctl get machinestatus --insecure --nodes "${IP}" >/dev/null 2>&1; do
        if (( SECONDS >= WAIT_DEADLINE )); then
            fail "Timed out waiting for ${IP} to return after Talos installation."
        fi
        sleep 2
    done
    log "✅ Talos is running from disk on ${IP}."
