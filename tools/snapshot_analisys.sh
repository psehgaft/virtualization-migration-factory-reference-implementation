#!/bin/bash
NAMESPACE="${NAMESPACE:-CHANGEME}"
REPORT="${REPORT:-/tmp/detailed_snapshots_report.txt}"
DELETE_LIST="${DELETE_LIST:-/tmp/snapshots_to_delete.txt}"
SEEN="${SEEN:-/tmp/pvcs_with_snap_seen.txt}"

if [[ "$NAMESPACE" == "CHANGEME" || -z "$NAMESPACE" ]]; then
  echo "ERROR: Set NAMESPACE to the target OpenShift namespace before running." >&2
  exit 2
fi
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc was not found in PATH." >&2; exit 1; }

echo -e "STATUS\tSNAPSHOT_NAME\tASSOCIATED_PVC\tREASON" > "$REPORT"
> "$DELETE_LIST"
> "$SEEN"

echo "Analyzing VMs, PVCs and Snapshots in $NAMESPACE..."

# 1. Get active PVCs mounted on the VMs
PVCS_IN_VMS=$(oc get vm -n "$NAMESPACE" -o jsonpath='{range .items[*].spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{.dataVolume.name}{"\n"}{end}' | sed '/^$/d' | sort -u)

# 2. Extract all snapshots and sort them by creation date (FROM NEWEST TO OLDEST)
oc get volumesnapshot -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.source.persistentVolumeClaimName}{"\t"}{.status.readyToUse}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}' | sort -k4 -r | while IFS=$'\t' read -r snap pvc ready date; do

  # A. Validate Failed
  if [[ "$ready" != "true" ]]; then
    echo -e "FAILED\t$snap\t$pvc\tThe snapshot returned an error or is not 'ReadyToUse'" | tee -a "$REPORT"
    echo "$snap" >> "$DELETE_LIST"
    continue
  fi

  # B. Validate Level 1 Orphans (The original PVC no longer exists in OpenShift)
  if ! oc get pvc "$pvc" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo -e "ORPHAN_WITHOUT_PVC\t$snap\t$pvc\tThe base PVC has already been deleted from the cluster" | tee -a "$REPORT"
    echo "$snap" >> "$DELETE_LIST"
    continue
  fi

  # C. Validate Level 2 Orphans (The PVC exists, but is disassociated from any VM)
  if ! echo "$PVCS_IN_VMS" | grep -qx "$pvc"; then
    echo -e "ORPHAN_WITHOUT_VM\t$snap\t$pvc\tThe PVC exists but is not connected to any active VM" | tee -a "$REPORT"
    echo "$snap" >> "$DELETE_LIST"
    continue
  fi

  # D. Validate Duplicates/Old (History of repeated copies)
  # Since we process from newest to oldest, the first one we read is the most recent.
  if grep -qx "$pvc" "$SEEN"; then
    echo -e "DUPLICATE/OLD\t$snap\t$pvc\tThere is a newer and healthier backup for this disk" | tee -a "$REPORT"
    echo "$snap" >> "$DELETE_LIST"
  else
    # If we haven't seen it, it is the main and most recent active snapshot (Do not delete)
    echo "$pvc" >> "$SEEN"
    echo -e "VALID_ACTIVE\t$snap\t$pvc\tMost recent main snapshot (KEEP)" | tee -a "$REPORT"
  fi

done

echo "======================================================================="
echo " Analysis finished."
echo " -> Review the full detail at: $REPORT"
echo " -> The exact list of items to delete is at: $DELETE_LIST"
