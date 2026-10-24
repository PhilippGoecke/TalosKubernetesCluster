#!/usr/bin/env bash
set -Eeuo pipefail

# Resets Talos nodes; it does not delete cloud/provider infrastructure.
# Defaults to a dry run. Pass --execute to perform the destructive reset.

usage() {
  cat <<'EOF'
Usage: destroy-talos-cluster.bash --cluster-name NAME --nodes NODE[,NODE...] \
  --talosconfig PATH [--execute]

Without --execute, prints the planned operations. Execution resets each node
to maintenance mode and wipes its system disk. It does not remove VMs,
networking, load balancers, or other provider resources.
EOF
}

cluster_name=""
nodes_csv=""
talosconfig=""
execute=false

while (($#)); do
  case "$1" in
    --cluster-name) (($# >= 2)) || { usage >&2; exit 2; }; cluster_name="$2"; shift 2 ;;
    --nodes)        (($# >= 2)) || { usage >&2; exit 2; }; nodes_csv="$2"; shift 2 ;;
    --talosconfig)  (($# >= 2)) || { usage >&2; exit 2; }; talosconfig="$2"; shift 2 ;;
    --execute) execute=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$cluster_name" || -z "$nodes_csv" || -z "$talosconfig" ]]; then
  usage >&2
  exit 2
fi
if [[ "$cluster_name" == *[!a-zA-Z0-9._-]* ]]; then
  printf 'Invalid cluster name. Use only letters, digits, ., _, and -.\n' >&2
  exit 2
fi
if [[ ! -r "$talosconfig" ]]; then
  printf 'Cannot read talosconfig: %s\n' "$talosconfig" >&2
  exit 2
fi
command -v talosctl >/dev/null 2>&1 || { printf 'talosctl not found in PATH.\n' >&2; exit 127; }

IFS=',' read -r -a nodes <<< "$nodes_csv"
((${#nodes[@]} > 0)) || { printf 'No nodes supplied.\n' >&2; exit 2; }
for node in "${nodes[@]}"; do
  if [[ -z "$node" || "$node" == *[!a-zA-Z0-9._:-]* ]]; then
    printf 'Invalid node value: %s\n' "$node" >&2
    exit 2
  fi
done

printf 'Cluster: %s\nNodes to reset: %s\n' "$cluster_name" "${nodes[*]}"
printf 'Action: reset nodes and wipe their Talos system disks.\n'
if [[ "$execute" != true ]]; then
  printf 'Dry run only. Re-run with --execute to proceed.\n'
  exit 0
fi

printf 'This is destructive and cannot be undone. Type the cluster name (%s) to confirm: ' "$cluster_name" >&2
IFS= read -r confirmation
if [[ "$confirmation" != "$cluster_name" ]]; then
  printf 'Confirmation did not match; no changes made.\n' >&2
  exit 1
fi

for node in "${nodes[@]}"; do
  printf 'Resetting %s...\n' "$node"
  talosctl --talosconfig "$talosconfig" --nodes "$node" reset --graceful --reboot --wait
done

printf 'Talos node reset requests completed. Remove provider resources separately if needed.\n'
