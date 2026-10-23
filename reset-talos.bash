#!/usr/bin/env bash
set -euo pipefail

# Wipe Talos configuration and ephemeral data, then reboot into maintenance mode.
# Requires an installed Talos system and an authorized talosconfig.
# Uses $TALOSCONFIG when set; otherwise uses $HOME/.talos/config.
# Usage: ./reset-talos.sh NODE_IP [API_ENDPOINT] [TALOS_CONTEXT]

if [[ $# -lt 1 || $# -gt 3 ]]; then
	printf 'Usage: %s NODE_IP [API_ENDPOINT] [TALOS_CONTEXT]\n' "$0" >&2
	exit 1
fi

command -v talosctl >/dev/null 2>&1 || {
	printf 'Error: talosctl is required.\n' >&2
	exit 1
}

talosconfig="${TALOSCONFIG:-${HOME}/.talos/config}"
if [[ ! -s "$talosconfig" ]]; then
	printf 'Error: Talos config file is missing or empty: %s\n' "$talosconfig" >&2
	printf 'Set TALOSCONFIG to a valid config file or create %s.\n' "${HOME}/.talos/config" >&2
	exit 1
fi

node="$1"
endpoint="${2:-$node}"
context="${3:-}"
talos_args=(--talosconfig "$talosconfig" --nodes "$node" --endpoints "$endpoint")
if [[ -n "$context" ]]; then
	talos_args+=(--context "$context")
fi

printf 'WARNING: This resets node %s and destroys its STATE and EPHEMERAL data.\n' "$node"
printf 'For Kubernetes nodes, migrate workloads first; preserve control-plane quorum.\n'
printf 'Type RESET to continue: '
read -r confirmation
if [[ "$confirmation" != RESET ]]; then
	printf 'Cancelled.\n'
	exit 1
fi

# Wiping STATE removes the machine configuration. Rebooting the installed Talos
# system without that configuration puts it into maintenance mode.
talosctl "${talos_args[@]}" reset \
	--graceful=true \
	--reboot=true \
	--system-labels-to-wipe STATE \
	--system-labels-to-wipe EPHEMERAL

printf 'After reboot, verify maintenance mode with:\n'
printf '  talosctl --nodes %q --endpoints %q version --insecure\n' "$node" "$node"
