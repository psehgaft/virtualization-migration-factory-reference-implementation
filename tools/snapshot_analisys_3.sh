#!/bin/bash
NAMESPACE="${NAMESPACE:-CHANGEME}"
FULL_REPORT="${FULL_REPORT:-/tmp/master_storage_audit_report.txt}"
DELETE_LIST_VS="${DELETE_LIST_VS:-/tmp/snapshots_to_delete.txt}"
DELETE_LIST_VSC="${DELETE_LIST_VSC:-/tmp/vsc_to_delete.txt}"
DELETE_LIST_PVC="${DELETE_LIST_PVC:-/tmp/pvcs_to_delete.txt}"
DELETE_LIST_PV="${DELETE_LIST_PV:-/tmp/pvs_to_delete.txt}"

if [[ "$NAMESPACE" == "CHANGEME" || -z "$NAMESPACE" ]]; then
  echo "ERROR: Set NAMESPACE to the target OpenShift namespace before running." >&2
  exit 2
fi
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc was not found in PATH." >&2; exit 1; }

# 1. Output files
FULL_REPORT="/tmp/master_storage_audit_report.txt"
DELETE_LIST_VS="/tmp/snapshots_to_delete.txt"
DELETE_LIST_VSC="/tmp/vsc_to_delete.txt"
DELETE_LIST_PVC="/tmp/pvcs_to_delete.txt"
DELETE_LIST_PV="/tmp/pvs_to_delete.txt"

# Temporary workspace
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PVCS_VMS="$TMP_DIR/pvcs_in_vms.txt"
PVCS_PODS="$TMP_DIR/pvcs_in_pods.txt"
PVCS_IN_USE="$TMP_DIR/pvcs_in_use.txt"
EXISTING_PVCS="$TMP_DIR/existing_pvcs.txt"
EXISTING_VS="$TMP_DIR/existing_vs.txt"
SEEN_PVCS="$TMP_DIR/seen_pvcs.txt"
VS_TO_DELETE_MAP="$TMP_DIR/vs_to_delete_map.txt"
PVCS_WITH_VALID_VS="$TMP_DIR/pvcs_with_valid_vs.txt"

# Initialize files
> "$FULL_REPORT"
> "$DELETE_LIST_VS"
> "$DELETE_LIST_VSC"
> "$DELETE_LIST_PVC"
> "$DELETE_LIST_PV"
> "$SEEN_PVCS"
> "$VS_TO_DELETE_MAP"
> "$PVCS_WITH_VALID_VS"

echo "=======================================================================" >> "$FULL_REPORT"
echo " MASTER STORAGE & SNAPSHOT AUDIT REPORT - NAMESPACE: $NAMESPACE" >> "$FULL_REPORT"
echo " Execution Date: $(date)" >> "$FULL_REPORT"
echo "=======================================================================" >> "$FULL_REPORT"

echo "[1/6] Gathering cluster inventory for namespace '$NAMESPACE'..."
# Extract PVCs mounted on VMs
oc get vm -n "$NAMESPACE" -o jsonpath='{range .items[*].spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{.dataVolume.name}{"\n"}{end}' | sed '/^$/d' | sort -u > "$PVCS_VMS"
# Extract PVCs mounted on active Pods
oc get pods -n "$NAMESPACE" -o jsonpath='{range .items[*].spec.volumes[*].persistentVolumeClaim}{.claimName}{"\n"}{end}' | sed '/^$/d' | sort -u > "$PVCS_PODS"
# Combine all in-use PVCs
sort -u "$PVCS_VMS" "$PVCS_PODS" | sed '/^$/d' > "$PVCS_IN_USE"
# Extract existing claims and snapshots
oc get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u > "$EXISTING_PVCS"
oc get volumesnapshot -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort -u > "$EXISTING_VS"

echo "[2/6] Auditing VolumeSnapshots (from newest to oldest)..."
echo -e "\n--- VOLUMESNAPSHOTS ---" >> "$FULL_REPORT"
echo -e "STATUS\tSNAPSHOT_NAME\tASSOCIATED_PVC\tBOUND_VSC\tREASON" >> "$FULL_REPORT"

oc get volumesnapshot -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.source.persistentVolumeClaimName}{"\t"}{.status.readyToUse}{"\t"}{.metadata.creationTimestamp}{"\t"}{.status.boundVolumeSnapshotContentName}{"\n"}{end}' \
  | sort -k4 -r | while IFS=$'\t' read -r snap pvc ready date vsc; do

  vsc_display="${vsc:-NONE}"
  del_reason=""

  if [[ "$ready" != "true" ]]; then
    del_reason="FAILED (readyToUse != true)"
    echo -e "FAILED\t$snap\t$pvc\t$vsc_display\t$del_reason" >> "$FULL_REPORT"
    echo "$snap" >> "$DELETE_LIST_VS"
    [[ -n "$vsc" ]] && echo -e "$vsc\t$snap\t$del_reason" >> "$VS_TO_DELETE_MAP"
    continue
  fi

  if ! grep -qx "$pvc" "$EXISTING_PVCS"; then
    del_reason="ORPHAN_WITHOUT_PVC (Base PVC was deleted)"
    echo -e "ORPHAN_WITHOUT_PVC\t$snap\t$pvc\t$vsc_display\t$del_reason" >> "$FULL_REPORT"
    echo "$snap" >> "$DELETE_LIST_VS"
    [[ -n "$vsc" ]] && echo -e "$vsc\t$snap\t$del_reason" >> "$VS_TO_DELETE_MAP"
    continue
  fi

  if ! grep -qx "$pvc" "$PVCS_IN_USE"; then
    del_reason="ORPHAN_WITHOUT_VM (PVC not bound to any active VM or Pod)"
    echo -e "ORPHAN_WITHOUT_VM\t$snap\t$pvc\t$vsc_display\t$del_reason" >> "$FULL_REPORT"
    echo "$snap" >> "$DELETE_LIST_VS"
    [[ -n "$vsc" ]] && echo -e "$vsc\t$snap\t$del_reason" >> "$VS_TO_DELETE_MAP"
    continue
  fi

  if grep -qx "$pvc" "$SEEN_PVCS"; then
    del_reason="DUPLICATE_OLD (Newer snapshot exists for this PVC)"
    echo -e "DUPLICATE_OLD\t$snap\t$pvc\t$vsc_display\t$del_reason" >> "$FULL_REPORT"
    echo "$snap" >> "$DELETE_LIST_VS"
    [[ -n "$vsc" ]] && echo -e "$vsc\t$snap\t$del_reason" >> "$VS_TO_DELETE_MAP"
  else
    echo "$pvc" >> "$SEEN_PVCS"
    echo "$pvc" >> "$PVCS_WITH_VALID_VS"
    echo -e "VALID_ACTIVE\t$snap\t$pvc\t$vsc_display\tMost recent healthy snapshot (KEEP)" >> "$FULL_REPORT"
  fi
done

echo "[3/6] Auditing VolumeSnapshotContents (cluster scope)..."
echo -e "\n--- VOLUMESNAPSHOTCONTENTS (Cluster Scope) ---" >> "$FULL_REPORT"
echo -e "STATUS\tVSC_NAME\tDELETION_POLICY\tREFERENCED_VS\tREASON" >> "$FULL_REPORT"

oc get volumesnapshotcontent -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.volumeSnapshotRef.namespace}{"\t"}{.spec.volumeSnapshotRef.name}{"\t"}{.spec.deletionPolicy}{"\t"}{.status.readyToUse}{"\n"}{end}' \
  | while IFS=$'\t' read -r vsc ns vs policy ready; do

  if [[ "$ns" != "$NAMESPACE" && -n "$ns" ]]; then
    continue
  fi

  match_vs=$(grep -m1 "^$vsc"$'\t' "$VS_TO_DELETE_MAP")
  if [[ -n "$match_vs" ]]; then
    orig_reason=$(echo "$match_vs" | cut -f3)
    echo -e "CONDEMNED_BY_VS\t$vsc\t$policy\t$vs\tLinked to marked VS [$orig_reason]" >> "$FULL_REPORT"
    echo "$vsc" >> "$DELETE_LIST_VSC"
    continue
  fi

  if [[ -z "$vs" ]] || ! grep -qx "$vs" "$EXISTING_VS"; then
    echo -e "ORPHAN_NO_VS\t$vsc\t$policy\t${vs:-NONE}\tReferenced VolumeSnapshot does not exist in cluster" >> "$FULL_REPORT"
    echo "$vsc" >> "$DELETE_LIST_VSC"
    continue
  fi

  if [[ "$ready" != "true" ]]; then
    echo -e "FAILED_BACKEND\t$vsc\t$policy\t$vs\tPhysical storage snapshot failed (readyToUse != true)" >> "$FULL_REPORT"
    echo "$vsc" >> "$DELETE_LIST_VSC"
    continue
  fi

  echo -e "VALID_ACTIVE\t$vsc\t$policy\t$vs\tLinked to a healthy, latest VolumeSnapshot (KEEP)" >> "$FULL_REPORT"
done

echo "[4/6] Auditing PersistentVolumeClaims (PVCs)..."
echo -e "\n--- PERSISTENT VOLUME CLAIMS (PVCs) ---" >> "$FULL_REPORT"
echo -e "STATUS\tPVC_NAME\tPHASE\tCAPACITY\tSTORAGECLASS\tREASON" >> "$FULL_REPORT"

oc get pvc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.capacity.storage}{"\t"}{.spec.storageClassName}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' \
  | while IFS=$'\t' read -r pvc phase cap sc del_ts; do

  cap_display="${cap:-N/A}"
  sc_display="${sc:-N/A}"

  if [[ -n "$del_ts" ]]; then
    echo -e "TERMINATING\t$pvc\t$phase\t$cap_display\t$sc_display\tDeletion in progress (unblocked once snapshots are deleted)" >> "$FULL_REPORT"
    continue
  fi

  if [[ "$phase" != "Bound" ]]; then
    echo -e "NOT_BOUND\t$pvc\t$phase\t$cap_display\t$sc_display\tPVC is in non-bound state ($phase)" >> "$FULL_REPORT"
    echo "$pvc" >> "$DELETE_LIST_PVC"
    continue
  fi

  if ! grep -qx "$pvc" "$PVCS_IN_USE"; then
    if grep -qx "$pvc" "$PVCS_WITH_VALID_VS"; then
      echo -e "ORPHAN_WITH_SNAPSHOT\t$pvc\t$phase\t$cap_display\t$sc_display\tUnattached to VMs, but has an active snapshot protecting it" >> "$FULL_REPORT"
    else
      echo -e "ORPHAN_UNATTACHED\t$pvc\t$phase\t$cap_display\t$sc_display\tNot mounted to any VM/Pod and has no active snapshots (Safe to delete)" >> "$FULL_REPORT"
      echo "$pvc" >> "$DELETE_LIST_PVC"
    fi
  else
    echo -e "VALID_ACTIVE\t$pvc\t$phase\t$cap_display\t$sc_display\tMounted to active VM or Pod (KEEP)" >> "$FULL_REPORT"
  fi
done

echo "[5/6] Auditing PersistentVolumes (PVs retained at backend)..."
echo -e "\n--- PERSISTENT VOLUMES (PVs) ---" >> "$FULL_REPORT"
echo -e "STATUS\tPV_NAME\tPHASE\tRECLAIM_POLICY\tCAPACITY\tCLAIM_REF\tREASON" >> "$FULL_REPORT"

oc get pv -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.persistentVolumeReclaimPolicy}{"\t"}{.spec.capacity.storage}{"\t"}{.spec.claimRef.namespace}{"\t"}{.spec.claimRef.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' \
  | while IFS=$'\t' read -r pv phase policy cap claim_ns claim_name del_ts; do

  if [[ "$claim_ns" != "$NAMESPACE" ]]; then
    continue
  fi

  cap_display="${cap:-N/A}"
  claim_ref_display="${claim_ns}/${claim_name}"

  if [[ "$phase" == "Released" || "$phase" == "Failed" || "$phase" == "Available" ]]; then
    echo -e "$phase\t$pv\t$phase\t$policy\t$cap_display\t$claim_ref_display\tPhysical volume retained at backend after claim deletion (Retain policy)" >> "$FULL_REPORT"
    echo "$pv" >> "$DELETE_LIST_PV"
    continue
  fi

  if [[ "$phase" == "Bound" ]]; then
    if ! grep -qx "$claim_name" "$EXISTING_PVCS"; then
      echo -e "ORPHAN_PVC_DELETED\t$pv\t$phase\t$policy\t$cap_display\t$claim_ref_display\tPV is Bound, but referenced claim '$claim_name' was deleted" >> "$FULL_REPORT"
      echo "$pv" >> "$DELETE_LIST_PV"
    else
      echo -e "VALID_BOUND\t$pv\t$phase\t$policy\t$cap_display\t$claim_ref_display\tBound to existing claim '$claim_name' (KEEP)" >> "$FULL_REPORT"
    fi
    continue
  fi

  echo -e "UNBOUND_$phase\t$pv\t$phase\t$policy\t$cap_display\t$claim_ref_display\tPV is in unhandled phase ($phase)" >> "$FULL_REPORT"
  echo "$pv" >> "$DELETE_LIST_PV"
done

# Deduplicate deletion lists
sort -u "$DELETE_LIST_VS" -o "$DELETE_LIST_VS"
sort -u "$DELETE_LIST_VSC" -o "$DELETE_LIST_VSC"
sort -u "$DELETE_LIST_PVC" -o "$DELETE_LIST_PVC"
sort -u "$DELETE_LIST_PV" -o "$DELETE_LIST_PV"

echo "[6/6] Generating Storage Capacity & Orphan Analyzer Report..."

echo -e "\n=======================================================================" | tee -a "$FULL_REPORT"
echo " STORAGE CAPACITY & CONSUMPTION SUMMARY" | tee -a "$FULL_REPORT"
echo "=======================================================================" | tee -a "$FULL_REPORT"
printf "%-55s %-12s %-10s %-15s\n" "PVC_NAME" "STATUS" "SIZE" "CONDITION" | tee -a "$FULL_REPORT"
echo "-----------------------------------------------------------------------" | tee -a "$FULL_REPORT"

oc get pvc -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,SIZE:.status.capacity.storage" --no-headers | \
awk -v vms_file="$PVCS_IN_USE" '
BEGIN {
    while ((getline line < vms_file) > 0) {
        in_vm[line] = 1
    }
    total_gb = 0; orphan_gb = 0; terminating_gb = 0;
}
{
    name=$1; status=$2; size=$3;
    val = size;
    gsub(/[a-zA-Z]+/, "", val);
    if (size ~ /Ti/) gb = val * 1024;
    else if (size ~ /Gi/) gb = val;
    else if (size ~ /Mi/) gb = val / 1024;
    else gb = val;

    total_gb += gb;

    if (name in in_vm) {
        condition = "ACTIVE_IN_VM_POD"
    } else {
        if (status == "Terminating") {
            condition = "TERMINATING"
            terminating_gb += gb;
        } else if (status == "Bound") {
            condition = "ORPHAN_BOUND"
            orphan_gb += gb;
        } else {
            condition = "ORPHAN_UNBOUND"
            orphan_gb += gb;
        }
    }
    printf "%-55s %-12s %-10s %-15s\n", name, status, size, condition
}
END {
    print "\n======================================================================="
    print " PVC CAPACITY SUMMARY"
    print "======================================================================="
    printf " Total provisioned (All PVCs)     : %8.2f GiB\n", total_gb
    printf " Total unattached (Free orphans)  : %8.2f GiB\n", orphan_gb
    printf " Total pending deletion           : %8.2f GiB\n", terminating_gb
}' | tee -a "$FULL_REPORT"

echo "" | tee -a "$FULL_REPORT"
echo "=======================================================================" | tee -a "$FULL_REPORT"
echo " PERSISTENT VOLUMES (PVs) RETAINED AT BACKEND LEVEL" | tee -a "$FULL_REPORT"
echo "=======================================================================" | tee -a "$FULL_REPORT"
oc get pv -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.namespace,SIZE:.spec.capacity.storage" --no-headers | awk -v ns="$NAMESPACE" '
BEGIN { found = 0 }
$4 == ns && ($2 == "Released" || $2 == "Failed" || $2 == "Available") {
    if (found == 0) {
        printf "%-45s %-10s %-10s %-10s\n", "PV_NAME", "STATUS", "POLICY", "SIZE"
        print "-----------------------------------------------------------------------"
        found = 1
    }
    printf "%-45s %-10s %-10s %-10s\n", $1, $2, $3, $5
}
END {
    if (found == 0) {
        print "Status clear: No residual physical volumes (Released/Failed/Available) found."
    } else {
        print "\nWARNING: The PVs listed above remain orphaned and allocated on the storage backend."
        print "If they have ReclaimPolicy: Retain, delete them manually via 'oc delete pv <PV_NAME>'."
    }
}' | tee -a "$FULL_REPORT"

echo ""
echo "======================================================================="
echo " STORAGE & SNAPSHOT AUDIT COMPLETED"
echo "======================================================================="
printf " VolumeSnapshots to delete        : %d\n" "$(wc -l < "$DELETE_LIST_VS")"
printf " VolumeSnapshotContents to delete : %d\n" "$(wc -l < "$DELETE_LIST_VSC")"
printf " PVCs to delete (Unbound/Orphans) : %d\n" "$(wc -l < "$DELETE_LIST_PVC")"
printf " PVs to delete (Released/Failed)  : %d\n" "$(wc -l < "$DELETE_LIST_PV")"
echo "-----------------------------------------------------------------------"
echo " Generated Files:"
echo "  [MASTER REPORT] : $FULL_REPORT"
echo "  [VS Delete]     : $DELETE_LIST_VS"
echo "  [VSC Delete]    : $DELETE_LIST_VSC"
echo "  [PVC Delete]    : $DELETE_LIST_PVC"
echo "  [PV Delete]     : $DELETE_LIST_PV"
echo "======================================================================="
