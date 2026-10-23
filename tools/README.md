# MTV audit tools

These utilities perform a **read-only audit** of Migration Toolkit for Virtualization (MTV, Forklift) on OpenShift clusters. They inspect operator and workload health, source Providers, NetworkMaps, StorageMaps, and—when available—live vCenter inventory. They write HTML reports and supporting YAML/JSON evidence locally.

Both scripts use the active `oc` login and kubeconfig. No cluster resources are created, changed, or deleted. Kubernetes Secret objects are intentionally excluded from exports.

## Scripts

| Script | Use it when | Requirements |
| --- | --- | --- |
| `mtv_cluster_audit.py` | You want the Python implementation, with per-cluster reports and machine-readable audit summaries. | Python 3.10+ (standard library only) and `oc`. |
| `mtv_cluster_audit.sh` | You want a Bash implementation suitable for RHEL 9 administration hosts. | Bash, `oc`, `jq`, and standard Unix utilities. |

The reports cover:

- MTV/Forklift CRDs, ClusterServiceVersions, controller resources, and deployments.
- Provider objects and status conditions.
- NetworkMap source-to-destination entries, including destination NetworkAttachmentDefinition checks.
- StorageMap source-to-StorageClass entries and destination StorageClass checks.
- Best-effort vCenter network and datastore inventory verification, when MTV's inventory service is reachable and the active account can query it.
- Exported MTV custom-resource YAML and destination network/storage YAML where supported. Secret objects are not exported.

An unavailable vCenter inventory is reported as **NOT VERIFIED**; it does not mean that the mapping is confirmed incorrect.

## Configure the default context

The scripts work with the current `oc` context by default. To make a copy use a specific default, replace the `CHANGEME` value in the `DEFAULT_CONTEXT` setting. Alternatively, set `MTV_AUDIT_CONTEXT` in the environment. Explicit `--context` or `--all-contexts` options determine the target context(s) for that run.

Check available contexts first:

```bash
oc config get-contexts
oc config current-context
```

The placeholder is not a credential. Do not put tokens, passwords, kubeconfig content, or vCenter credentials in these scripts.

## Examples

Run the Python audit against the current context:

```bash
python3 tools/mtv_cluster_audit.py
```

Audit two named contexts and choose an output directory:

```bash
python3 tools/mtv_cluster_audit.py \
  --context CHANGEME-HUB-CONTEXT \
  --context CHANGEME-MANAGED-CONTEXT \
  --output-dir ./mtv-audit-results
```

Run the Bash implementation on RHEL 9:

```bash
bash tools/mtv_cluster_audit.sh --context CHANGEME-CLUSTER-CONTEXT
```

Audit all contexts in the current kubeconfig:

```bash
python3 tools/mtv_cluster_audit.py --all-contexts
# or
bash tools/mtv_cluster_audit.sh --all-contexts
```

Skip live vCenter inventory lookups when you only want to validate objects and destination resources:

```bash
python3 tools/mtv_cluster_audit.py --no-vcenter-inventory
bash tools/mtv_cluster_audit.sh --no-vcenter-inventory
```

Use `--help` for the full options. Both scripts also support `--timeout SECONDS` and `--output-dir DIRECTORY`.

## Output and exit codes

Each run creates a timestamped output directory by default. It contains a per-context report named `mtv-audit-report.html`, exported resource YAML, and raw supporting data. The Python implementation additionally writes `audit-summary.json`; both implementations write a top-level `index.html`.

Protect the output directory according to your organization's data-handling rules. Although Secrets are excluded, exported custom resources and inventory details may contain infrastructure information.

Exit codes are:

| Code | Meaning |
| --- | --- |
| `0` | Audit completed without failed checks. |
| `1` | A fatal execution or dependency error occurred. |
| `2` | The audit completed and found one or more failed checks (or a cluster-level failure). |

## Access needed

Use an account with read permissions for MTV/Forklift resources, CRDs, CSVs, deployments, services, NetworkAttachmentDefinitions, StorageClasses, and cluster version information. The report will show warnings or failed checks for resources the account cannot inspect.

## Storage and cluster diagnostics

The following scripts were added for storage snapshot review and broader OpenShift Virtualization/MTV diagnostics. They use the currently selected `oc` context; check it with `oc config current-context` before running them. Reports and candidate lists can expose cluster topology, resource names, and configuration, so protect the generated files.

| Script | Purpose | Behavior |
| --- | --- | --- |
| `snapshot_analisys.sh` | Reviews VolumeSnapshots in one namespace for failed snapshots, missing PVCs, PVCs not attached to VMs, and older duplicates. | Read-only; writes a report and a candidate list at `DELETE_LIST`. |
| `snapshot_analisys_2.sh` | Collects an extended cluster health report for OpenShift, OpenShift Virtualization (CNV), MTV, and storage, plus a targeted namespace PVC summary. | Read-only; writes `REPORT`. |
| `snapshot_analisys_3.sh` | Audits snapshot, VolumeSnapshotContent, PVC, PV, and capacity relationships for one namespace. | Read-only; writes a detailed report and separate candidate lists for snapshots, snapshot contents, PVCs, and PVs. Review every candidate manually; it does not delete resources. |
| `cleaner.sh` | Deletes VolumeSnapshots named in a reviewed list. | **Destructive.** Requires a namespace other than `CHANGEME` and typed confirmation of that namespace. It does not delete PVCs or PVs. |

### Configure and run

Set `NAMESPACE` to the workload namespace. The scripts also accept environment overrides for report and candidate-list paths. The MTV namespace in the extended report is separately configurable as `MTV_NAMESPACE`.

```bash
oc config current-context
NAMESPACE=your-workload-namespace bash tools/snapshot_analisys.sh
```

Run the broader health report and specify the MTV namespace if it differs from `openshift-mtv`:

```bash
NAMESPACE=your-workload-namespace \
MTV_NAMESPACE=your-mtv-namespace \
REPORT=./cluster-health-report.txt \
bash tools/snapshot_analisys_2.sh
```

Run the detailed storage audit with custom output paths:

```bash
NAMESPACE=your-workload-namespace \
FULL_REPORT=./storage-audit.txt \
DELETE_LIST_VS=./snapshots-to-review.txt \
DELETE_LIST_VSC=./snapshot-contents-to-review.txt \
DELETE_LIST_PVC=./pvcs-to-review.txt \
DELETE_LIST_PV=./pvs-to-review.txt \
bash tools/snapshot_analisys_3.sh
```

### Snapshot cleanup workflow

The first and third analysis scripts can write a VolumeSnapshot candidate list. Review the list and report first, then run the cleaner with the same namespace and list path. The cleaner prints the active context and every snapshot name, then requires the exact namespace to be typed before it calls `oc delete`.

```bash
NAMESPACE=your-workload-namespace \
DELETE_LIST=./snapshots-to-review.txt \
bash tools/cleaner.sh
```

The cleaner only handles VolumeSnapshots. The other candidate lists produced by `snapshot_analisys_3.sh` are report artifacts; no script in this folder automatically deletes VolumeSnapshotContents, PVCs, or PVs. Validate ownership, retention policy, backup coverage, and application impact before any cleanup.
