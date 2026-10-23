#!/bin/bash

# Define specific namespace for localized searches if needed (Storage analyzer will check globally to find ALL orphans)
NAMESPACE="${NAMESPACE:-CHANGEME}"
MTV_NAMESPACE="${MTV_NAMESPACE:-CHANGEME}"
REPORT="${REPORT:-report.txt}"

if [[ "$NAMESPACE" == "CHANGEME" || -z "$NAMESPACE" ]]; then
  echo "ERROR: Set NAMESPACE to the target OpenShift namespace before running." >&2
  exit 2
fi
if [[ "$MTV_NAMESPACE" == "CHANGEME" || -z "$MTV_NAMESPACE" ]]; then
  echo "ERROR: Set MTV_NAMESPACE to the namespace where MTV is installed." >&2
  exit 2
fi
command -v oc >/dev/null 2>&1 || { echo "ERROR: oc was not found in PATH." >&2; exit 1; }

echo "==================================================" | tee "$REPORT"
echo "   OPENSHIFT, CNV & MTV EXTENDED HEALTH CHECK    " | tee -a report.txt
echo "   Execution Date: $(date)                       " | tee -a report.txt
echo "==================================================" | tee -a report.txt

echo -e "\n--- 1.1 Cluster Version & Basic Info ---" | tee -a report.txt
oc version 2>&1 | tee -a report.txt

oc cluster-info 2>&1 | tee -a report.txt

oc get clusterversion 2>&1 | tee -a report.txt

echo -e "\n--- 1.2 Cluster Version Detailed Status ---" | tee -a report.txt
oc describe clusterversion 2>&1 | tee -a report.txt

echo -e "\n--- 1.3 Infrastructure, Scheduler & Proxy Config ---" | tee -a report.txt
oc get infrastructure cluster 2>&1 | tee -a report.txt

oc get apiserver cluster 2>&1 | tee -a report.txt

oc get proxy cluster 2>&1 | tee -a report.txt

oc get subscriptions -A 2>&1 | tee -a report.txt

oc get csv -A 2>&1 | tee -a report.txt

echo -e "\n--- 2.1 Cluster Nodes Overview ---" | tee -a report.txt
oc get nodes -o wide 2>&1 | tee -a report.txt

echo -e "\n--- 2.2 Node Conditions & Hardware Summary ---" | tee -a report.txt
oc get nodes -o custom-columns=NAME:.metadata.name,STATUS:.status.conditions[-1].type,REASON:.status.conditions[-1].reason,KERNEL:.status.nodeInfo.kernelVersion,OS:.status.nodeInfo.osImage 2>&1 | tee -a report.txt

echo -e "\n--- 2.3 Node Labels & CSRs ---" | tee -a report.txt
oc get nodes --show-labels 2>&1 | tee -a report.txt

oc get csr 2>&1 | tee -a report.txt

echo -e "\n--- 2.4 Detailed Node Inspection (CPU, RAM, Conditions, Kubelet) ---" | tee -a report.txt
oc describe nodes 2>&1 | tee -a report.txt

echo -e "\n--- 3.1 Cluster Operators Summary ---" | tee -a report.txt
oc get co 2>&1 | tee -a report.txt

echo -e "\n--- 3.2 Non-Available Cluster Operators List ---" | tee -a report.txt
oc get co -o jsonpath='{range .items[?(@.status.conditions[?(@.type=="Available")].status=="False")]}{.metadata.name}{"\n"}{end}' 2>&1 | tee -a report.txt

echo -e "\n--- 3.3 Detailed Status of Degrading/Unavailable Cluster Operators ---" | tee -a report.txt
oc describe co $(oc get co --no-headers | grep -v 'True.*False.*False' | awk '{print $1}') 2>&1 | tee -a report.txt

echo -e "\n--- 4.1 MachineConfigPools (MCP) & MachineConfigs Overview ---" | tee -a report.txt
oc get mcp 2>&1 | tee -a report.txt

oc get machineconfig 2>&1 | tee -a report.txt

oc get kubeletconfig 2>&1 | tee -a report.txt

echo -e "\n--- 4.2 Detailed MachineConfigPools Inspection ---" | tee -a report.txt
oc describe mcp 2>&1 | tee -a report.txt

echo -e "\n--- 5.1 Non-Running or Failed Pods Across All Namespaces ---" | tee -a report.txt
oc get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded 2>&1 | tee -a report.txt

echo -e "\n--- 5.2 Detailed Description of Non-Ready / Crashing Pods ---" | tee -a report.txt
oc get pods -A --field-selector status.phase!=Running,status.phase!=Succeeded --no-headers | awk '{print "oc describe pod " $2 " -n " $1}' | sh 2>&1 | tee -a report.txt

echo -e "\n--- 6.1 StorageClasses & PV Summary ---" | tee -a report.txt
oc get sc 2>&1 | tee -a report.txt

oc get pv 2>&1 | tee -a report.txt

echo -e "\n--- 6.2 Detailed StorageClasses Inspection ---" | tee -a report.txt
oc describe sc 2>&1 | tee -a report.txt

echo -e "\n--- 6.3 Unbound or Pending PersistentVolumeClaims (PVCs) ---" | tee -a report.txt
oc get pvc -A --field-selector status.phase!=Bound 2>&1 | tee -a report.txt

echo -e "\n--- 6.4 Detailed Description of Unbound PVCs ---" | tee -a report.txt
oc get pvc -A --field-selector status.phase!=Bound --no-headers | awk '{print "oc describe pvc " $2 " -n " $1}' | sh 2>&1 | tee -a report.txt

echo -e "\n--- 7.1 Networking (Multus, Ingress, Network Operators) ---" | tee -a report.txt
oc get net-attach-def -A 2>&1 | tee -a report.txt

oc get network.config.openshift.io cluster 2>&1 | tee -a report.txt

oc get network.operator.openshift.io cluster 2>&1 | tee -a report.txt

oc get ingresscontroller -n openshift-ingress-operator 2>&1 | tee -a report.txt

echo -e "\n--- 7.2 Detailed NetworkAttachmentDefinitions Inspection ---" | tee -a report.txt
oc describe net-attach-def -A 2>&1 | tee -a report.txt

echo -e "\n--- 8.1 OpenShift Virtualization (CNV) Operators & CSV Status ---" | tee -a report.txt
oc get csv -n openshift-cnv 2>&1 | tee -a report.txt

echo -e "\n--- 8.2 HyperConverged & KubeVirt Custom Resources ---" | tee -a report.txt
oc get hyperconverged -n openshift-cnv 2>&1 | tee -a report.txt

oc describe hyperconverged -n openshift-cnv 2>&1 | tee -a report.txt

oc get kubevirt -n openshift-cnv 2>&1 | tee -a report.txt

echo -e "\n--- 8.3 CNV Infrastructure Pods ---" | tee -a report.txt
oc get pods -n openshift-cnv -o wide 2>&1 | tee -a report.txt

oc describe pods -n openshift-cnv 2>&1 | tee -a report.txt

echo -e "\n--- 8.4 VirtualMachines & VirtualMachineInstances List ---" | tee -a report.txt
oc get vm,vmi -A 2>&1 | tee -a report.txt

echo -e "\n--- 8.5 Detailed Description of All VirtualMachines (VM) ---" | tee -a report.txt
oc describe vm -A 2>&1 | tee -a report.txt

echo -e "\n--- 8.6 Detailed Description of All VirtualMachineInstances (VMI) ---" | tee -a report.txt
oc describe vmi -A 2>&1 | tee -a report.txt

echo -e "\n--- 9.1 MTV Operator CSV & Controller Pods ---" | tee -a report.txt
oc get csv -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc get pods -n "$MTV_NAMESPACE" -o wide 2>&1 | tee -a report.txt

oc describe pods -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

echo -e "\n--- 9.2 MTV Providers (VMware / Host) ---" | tee -a report.txt
oc get providers.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc describe providers.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

echo -e "\n--- 9.3 MTV StorageMaps & NetworkMaps Detailed Config ---" | tee -a report.txt
oc get storagemap,networkmap -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc describe storagemap.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc describe networkmap.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

echo -e "\n--- 9.4 MTV Migration Plans & Resources Inspection ---" | tee -a report.txt
oc get plan.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc describe plan.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc get migration.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

oc describe migration.forklift.konveyor.io -n "$MTV_NAMESPACE" 2>&1 | tee -a report.txt

echo -e "\n--- 10.1 Security, Auth & Core Services (SCC, OAuth, Etcd, Registry) ---" | tee -a report.txt
oc get scc 2>&1 | tee -a report.txt

oc get oauth cluster 2>&1 | tee -a report.txt

oc get clusterrolebinding 2>&1 | tee -a report.txt

oc get rolebinding -A 2>&1 | tee -a report.txt

oc get etcd cluster 2>&1 | tee -a report.txt

oc get pods -n openshift-etcd 2>&1 | tee -a report.txt

oc get configs.imageregistry.operator.openshift.io cluster 2>&1 | tee -a report.txt

echo -e "\n--- 10.2 Day-2 Configs (Quotas, Limits, Image Pruning) ---" | tee -a report.txt
oc get resourcequota -A 2>&1 | tee -a report.txt

oc get limitrange -A 2>&1 | tee -a report.txt

oc get image.config.openshift.io cluster 2>&1 | tee -a report.txt

oc get dc -A 2>&1 | tee -a report.txt

oc get jobs -A 2>&1 | tee -a report.txt

echo -e "\n--- 11.1 Layered Products Check (ACM, ACS, Logging, Pipelines, Mesh) ---" | tee -a report.txt
oc get multiclusterhub -n open-cluster-management 2>&1 | tee -a report.txt

oc get central -n stackrox 2>&1 | tee -a report.txt

oc get clusterlogging instance -n openshift-logging 2>&1 | tee -a report.txt

oc get lokistack -n openshift-logging 2>&1 | tee -a report.txt

oc get tektonconfig cluster 2>&1 | tee -a report.txt

oc get servicemeshcontrolplane -A 2>&1 | tee -a report.txt

oc get knativeserving -A 2>&1 | tee -a report.txt

oc get quayregistry -A 2>&1 | tee -a report.txt

oc get datasciencecluster -A 2>&1 | tee -a report.txt

echo -e "\n--- 12.1 Cluster Warning Events Dump ---" | tee -a report.txt
oc get events -A --field-selector type=Warning --sort-by='.lastTimestamp' 2>&1 | tee -a report.txt

echo -e "\n--- 13.1 Real-Time Node Resource Metrics ---" | tee -a report.txt
oc adm top nodes 2>&1 | tee -a report.txt

echo -e "\n--- 13.2 Top Pods Resource Usage (CPU & Memory) ---" | tee -a report.txt
oc adm top pods -A --sort-by=cpu 2>&1 | head -n 30 | tee -a report.txt

oc adm top pods -A --sort-by=memory 2>&1 | head -n 30 | tee -a report.txt

echo -e "\n--- 14.1 Storage Usage & Orphaned PVCs Analysis (Cluster-Wide & Target Namespace) ---" | tee -a report.txt
PVCS_VMS=$(mktemp)
# Extract all PVCs actively attached to VMs across the cluster
oc get vm -A -o jsonpath='{range .items[*].spec.template.spec.volumes[*]}{.persistentVolumeClaim.claimName}{"\n"}{.dataVolume.name}{"\n"}{end}' | sed '/^$/d' | sort -u > "$PVCS_VMS"

printf "%-55s %-15s %-12s %-10s %-15s\n" "PVC_NAME" "NAMESPACE" "STATUS" "SIZE" "CONDITION" | tee -a report.txt
echo "-------------------------------------------------------------------------------------------------------------------" | tee -a report.txt

# Evaluate capacity, status, and orphan condition for all PVCs in the targeted namespace
oc get pvc -n "$NAMESPACE" -o custom-columns="NAME:.metadata.name,NS:.metadata.namespace,STATUS:.status.phase,SIZE:.status.capacity.storage" --no-headers | \
awk -v vms_file="$PVCS_VMS" '
BEGIN {
    while ((getline line < vms_file) > 0) {
        in_vm[line] = 1
    }
    total_gb = 0; orphan_gb = 0; terminating_gb = 0;
}
{
    name=$1; ns=$2; status=$3; size=$4;

    # Normalize capacity to GiB
    val = size;
    gsub(/[a-zA-Z]+/, "", val);
    if (size ~ /Ti/) gb = val * 1024;
    else if (size ~ /Gi/) gb = val;
    else if (size ~ /Mi/) gb = val / 1024;
    else gb = val;

    total_gb += gb;

    if (name in in_vm) {
        condition = "ACTIVE_IN_VM"
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

    printf "%-55s %-15s %-12s %-10s %-15s\n", name, ns, status, size, condition
}
END {
    print "\n--- PVC CAPACITY SUMMARY (" ns ") ---"
    printf " Total provisioned (All PVCs)     : %8.2f GiB\n", total_gb
    printf " Total unattached (Free orphans)  : %8.2f GiB\n", orphan_gb
    printf " Total pending deletion           : %8.2f GiB\n", terminating_gb
}' | tee -a report.txt

rm -f "$PVCS_VMS"

echo -e "\n--- 14.2 Persistent Volumes (PVs) Retained at Backend Level (Cluster-Wide Orphans) ---" | tee -a report.txt
# Check for cluster-level PVs that are Released, Failed, or Available across ALL namespaces
oc get pv -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,RECLAIM:.spec.persistentVolumeReclaimPolicy,CLAIM:.spec.claimRef.namespace,SIZE:.spec.capacity.storage" --no-headers | awk '
BEGIN { found = 0 }
($2 == "Released" || $2 == "Failed" || $2 == "Available") {
    if (found == 0) {
        printf "%-45s %-12s %-10s %-10s\n", "PV_NAME", "STATUS", "POLICY", "SIZE"
        print "---------------------------------------------------------------------------------"
        found = 1
    }
    printf "%-45s %-12s %-10s %-10s\n", $1, $2, $3, $5
}
END {
    if (found == 0) {
        print "Status clear: No residual physical volumes (Released/Failed/Available) found cluster-wide."
    } else {
        print "\nWARNING: The PVs listed above remain orphaned and allocated on the storage backend."
        print "If they have ReclaimPolicy: Retain, delete them manually via 'oc delete pv <PV_NAME>'."
    }
}' | tee -a report.txt

echo -e "\n==================================================" | tee -a report.txt
echo "   EXTENDED REPORT GENERATION COMPLETED           " | tee -a report.txt
echo "==================================================" | tee -a report.txt
