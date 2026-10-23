#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-CHANGEME}"
DELETE_LIST="${DELETE_LIST:-/tmp/snapshots_to_delete.txt}"

if [[ "$NAMESPACE" == "CHANGEME" || -z "$NAMESPACE" ]]; then
  echo "ERROR: Set NAMESPACE to the target OpenShift namespace before running." >&2
  exit 2
fi
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc was not found in PATH." >&2; exit 1; }
[[ -r "$DELETE_LIST" ]] || { echo "ERROR: Cannot read delete list: $DELETE_LIST" >&2; exit 1; }

mapfile -t SNAPSHOTS < <(sed '/^[[:space:]]*$/d' "$DELETE_LIST")
(("${#SNAPSHOTS[@]}" > 0)) || { echo "No snapshots are listed for deletion."; exit 0; }

for snap in "${SNAPSHOTS[@]}"; do
  [[ "$snap" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
    echo "ERROR: Invalid VolumeSnapshot name in delete list: $snap" >&2
    exit 1
  }
done

CURRENT_CONTEXT="$(oc config current-context 2>/dev/null || true)"
[[ -n "$CURRENT_CONTEXT" ]] || { echo "ERROR: No current oc context is selected." >&2; exit 1; }

echo "Target context : $CURRENT_CONTEXT"
echo "Target namespace: $NAMESPACE"
echo "Delete list     : $DELETE_LIST"
printf 'Snapshots to delete (%d):\n' "${#SNAPSHOTS[@]}"
printf '  %s\n' "${SNAPSHOTS[@]}"
read -r -p "Type the namespace '$NAMESPACE' to confirm deletion: " confirmation
if [[ "$confirmation" != "$NAMESPACE" ]]; then
  echo "Operation canceled."
  exit 0
fi

for snap in "${SNAPSHOTS[@]}"; do
  echo "Deleting VolumeSnapshot: $snap"
  oc delete volumesnapshot "$snap" -n "$NAMESPACE"
done

echo "Snapshot cleanup completed."
echo "PVCs and PVs are not deleted by this script."
