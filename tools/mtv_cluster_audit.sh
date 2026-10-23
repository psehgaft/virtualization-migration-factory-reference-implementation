#!/usr/bin/env bash
# Migration Toolkit for Virtualization (MTV) audit for OpenShift.
# RHEL 9 compatible. Read-only: this script does not modify cluster resources.
# Requirements: bash, oc, jq, sed, awk, grep, coreutils.

set -uo pipefail

VERSION="1.0.0"
MTV_GROUP="forklift.konveyor.io"
TIMEOUT=30
OUTPUT_DIR="mtv-audit-$(date +%Y%m%d-%H%M%S)"
ALL_CONTEXTS=false
# Set MTV_AUDIT_CONTEXT or replace CHANGEME to pin a default kubeconfig context.
DEFAULT_CONTEXT="${MTV_AUDIT_CONTEXT:-CHANGEME}"
NO_VCENTER_INVENTORY=false
declare -a CONTEXTS=()

usage() {
  cat <<'EOF'
MTV Cluster Audit for OpenShift

Usage:
  ./mtv_cluster_audit.sh [options]

Options:
  --context NAME             Audit this kubeconfig context. Repeat as needed.
  --all-contexts             Audit every context in the active kubeconfig.
  --output-dir DIRECTORY     Output directory.
  --timeout SECONDS          Timeout for each oc request. Default: 30.
  --no-vcenter-inventory     Skip live vCenter network/datastore inventory lookup.
  -h, --help                 Show this help.

Exit codes:
  0  Audit completed without failed checks.
  1  Fatal execution or dependency error.
  2  Audit completed and one or more failed checks were found.
EOF
}

while (($#)); do
  case "$1" in
    --context)
      [[ $# -ge 2 ]] || { echo "ERROR: --context requires a value" >&2; exit 1; }
      CONTEXTS+=("$2"); shift 2 ;;
    --all-contexts) ALL_CONTEXTS=true; shift ;;
    --output-dir)
      [[ $# -ge 2 ]] || { echo "ERROR: --output-dir requires a value" >&2; exit 1; }
      OUTPUT_DIR="$2"; shift 2 ;;
    --timeout)
      [[ $# -ge 2 ]] || { echo "ERROR: --timeout requires a value" >&2; exit 1; }
      TIMEOUT="$2"; shift 2 ;;
    --no-vcenter-inventory) NO_VCENTER_INVENTORY=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

for command in oc jq sed awk grep date mkdir basename dirname base64 tr sort wc; do
  command -v "$command" >/dev/null 2>&1 || { echo "ERROR: required command '$command' was not found" >&2; exit 1; }
done
[[ "$TIMEOUT" =~ ^[0-9]+$ ]] && ((TIMEOUT >= 5)) || { echo "ERROR: --timeout must be an integer of at least 5" >&2; exit 1; }
if $ALL_CONTEXTS && ((${#CONTEXTS[@]})); then
  echo "ERROR: --all-contexts cannot be combined with --context" >&2
  exit 1
fi
if $ALL_CONTEXTS; then
  mapfile -t CONTEXTS < <(oc config get-contexts -o name 2>/dev/null)
elif ((${#CONTEXTS[@]} == 0)); then
  current_context="$(oc config current-context 2>/dev/null || true)"
  [[ -n "$current_context" ]] && CONTEXTS+=("$current_context")
fi
((${#CONTEXTS[@]})) || { echo "ERROR: no OpenShift context was selected or found" >&2; exit 1; }

OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

safe_name() {
  local value="$1"
  value="$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9_.-]+/_/g; s/^_+//; s/_+$//')"
  printf '%.180s' "${value:-unnamed}"
}

clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

html_escape() {
  jq -Rr @html <<<"${1:-}"
}

oc_ctx() {
  oc --context "$CURRENT_CONTEXT" --request-timeout "${TIMEOUT}s" "$@"
}

finding() {
  local severity="$1" component="$2" message="$3"
  printf '%s\t%s\t%s\n' "$(clean_field "$severity")" "$(clean_field "$component")" "$(clean_field "$message")" >>"$FINDINGS"
}

yaml_record() {
  printf '%s\n' "$1" >>"$YAML_FILES"
}

status_badge() {
  local value="$1" class="info"
  case "$value" in
    PASS|Succeeded) class="pass" ;;
    FAIL|Failed) class="fail" ;;
    WARN|"NOT VERIFIED"|Pending|Unknown) class="warn" ;;
  esac
  printf '<span class="badge %s">%s</span>' "$class" "$(html_escape "$value")"
}

conditions_health() {
  local object_json="$1" negative positive detail
  negative="$(jq '[.status.conditions[]? | (.type // "" | ascii_downcase) as $t | (.status // "" | ascii_downcase) as $s | select(($s == "true" and ($t | test("failed|error|degraded"))) or ($s == "false" and ($t | test("ready|succeeded|connected|inventorycreated"))))] | length' <<<"$object_json")"
  positive="$(jq '[.status.conditions[]? | (.type // "" | ascii_downcase) as $t | (.status // "" | ascii_downcase) as $s | select($s == "true" and ($t | test("ready|succeeded|connected|inventorycreated")))] | length' <<<"$object_json")"
  detail="$(jq -r 'if ((.status.conditions // []) | length) == 0 then "No status conditions are published" else [.status.conditions[]? | "\(.type // "Unknown")=\(.status // "Unknown")" + (if (.reason // "") != "" then " (\(.reason))" else "" end)] | join("; ") end' <<<"$object_json")"
  if ((negative > 0)); then
    printf 'FAIL\t%s\n' "$(clean_field "$detail")"
  elif ((positive > 0)); then
    printf 'PASS\t%s\n' "$(clean_field "$detail")"
  else
    printf 'WARN\t%s\n' "$(clean_field "$detail")"
  fi
}

export_resource_set() {
  local label="$1" resource="$2" json_file="$3" folder="$CLUSTER_DIR/yaml/$label"
  mkdir -p "$folder"
  while IFS=$'\t' read -r namespace name; do
    [[ -n "$name" ]] || continue
    local target="$folder/$(safe_name "${namespace:-cluster}")__$(safe_name "$name").yaml"
    local -a args=(get "$resource" "$name")
    [[ -n "$namespace" ]] && args+=(-n "$namespace")
    args+=(-o yaml --show-managed-fields=false)
    if oc_ctx "${args[@]}" >"$target" 2>"$TMP_ERROR"; then
      yaml_record "${target#"$CLUSTER_DIR/"}"
    else
      finding WARN "YAML export" "Could not export $label/${namespace:-cluster}/$name: $(<"$TMP_ERROR")"
    fi
  done < <(jq -r '.items[]? | [(.metadata.namespace // ""), .metadata.name] | @tsv' "$json_file")
  local bulk="$CLUSTER_DIR/yaml/all-${label}.yaml"
  if oc_ctx get "$resource" -A -o yaml --show-managed-fields=false >"$bulk" 2>/dev/null; then
    yaml_record "${bulk#"$CLUSTER_DIR/"}"
  fi
}

export_destination() {
  local resource="$1" name="$2" namespace="$3" target="$4"
  local -a args=(get "$resource" "$name")
  [[ -n "$namespace" ]] && args+=(-n "$namespace")
  args+=(-o yaml --show-managed-fields=false)
  mkdir -p "$(dirname "$target")"
  if oc_ctx "${args[@]}" >"$target" 2>"$TMP_ERROR"; then
    yaml_record "${target#"$CLUSTER_DIR/"}"
  else
    finding WARN "YAML export" "Could not export destination $resource/${namespace:-cluster}/$name: $(<"$TMP_ERROR")"
  fi
}

inventory_query() {
  local provider_uid="$1" provider_type="$2" kind="$3" output="$4"
  local service_ns service_name token endpoint prefix raw_file
  provider_type="${provider_type,,}"
  case "$provider_type" in vcenter|vmware) provider_type="vsphere" ;; esac
  raw_file="$CLUSTER_DIR/inventory/.raw-${provider_uid}-${kind}.json"
  while IFS=$'\t' read -r service_ns service_name token; do
    [[ -n "$service_ns" && -n "$service_name" && -n "$token" ]] || continue
    for prefix in \
      "/api/v1/namespaces/${service_ns}/services/http:${service_name}:${token}/proxy" \
      "/api/v1/namespaces/${service_ns}/services/${service_name}:${token}/proxy"; do
      for endpoint in \
        "/providers/${provider_type}/${provider_uid}/${kind}" \
        "/providers/${provider_uid}/inventory/${kind}" \
        "/providers/${provider_uid}/${kind}"; do
        if oc_ctx get --raw "${prefix}${endpoint}" >"$raw_file" 2>/dev/null && jq -e . "$raw_file" >/dev/null 2>&1; then
          jq 'if type == "array" then . elif (.items? | type) == "array" then .items elif (.resources? | type) == "array" then .resources elif (.data? | type) == "array" then .data else [] end' "$raw_file" >"$output"
          return 0
        fi
      done
    done
  done < <(jq -r '.items[]? | select((.metadata.name // "") | ascii_downcase | contains("inventory")) | . as $s | (.spec.ports // [{"port":80}])[] | [$s.metadata.namespace, $s.metadata.name, (.name // .port // 80 | tostring)] | @tsv' "$SERVICES_JSON")
  printf '[]\n' >"$output"
  return 1
}

inventory_has() {
  local inventory_file="$1" wanted="${2,,}"
  jq -e --arg wanted "$wanted" '[.. | objects | .id?, .name?, .uid?, .path?, .moref?, .moRef?, .objectid?, .objectID? | select(. != null) | tostring | ascii_downcase] | index($wanted) != null' "$inventory_file" >/dev/null 2>&1
}

render_table() {
  local file="$1" headers="$2" status_column="${3:--1}"
  if [[ ! -s "$file" ]]; then
    printf '<p class="empty">No items found.</p>\n'
    return
  fi
  printf '<div class="table-wrap"><table><thead><tr>'
  local IFS='|' header
  for header in $headers; do printf '<th>%s</th>' "$(html_escape "$header")"; done
  printf '</tr></thead><tbody>\n'
  while IFS=$'\t' read -r -a columns; do
    printf '<tr>'
    local i
    for i in "${!columns[@]}"; do
      if ((i == status_column)); then
        printf '<td>%s</td>' "$(status_badge "${columns[$i]}")"
      else
        printf '<td>%s</td>' "$(html_escape "${columns[$i]}")"
      fi
    done
    printf '</tr>\n'
  done <"$file"
  printf '</tbody></table></div>\n'
}

render_cluster_report() {
  local pass_count warn_count fail_count overall
  pass_count="$(awk -F '\t' '$1=="PASS"{n++} END{print n+0}' "$FINDINGS")"
  warn_count="$(awk -F '\t' '$1=="WARN"{n++} END{print n+0}' "$FINDINGS")"
  fail_count="$(awk -F '\t' '$1=="FAIL"{n++} END{print n+0}' "$FINDINGS")"
  overall=PASS; ((warn_count > 0)) && overall=WARN; ((fail_count > 0)) && overall=FAIL
  REPORT_STATUS="$overall"
  REPORT_FAILURES="$fail_count"
  REPORT_WARNINGS="$warn_count"
  {
    cat <<EOF
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTV Audit - $(html_escape "$CURRENT_CONTEXT")</title><style>
:root{--bg:#f3f6f8;--card:#fff;--text:#151515;--muted:#6a6e73;--line:#d2d2d2;--red:#c9190b;--green:#3e8635;--amber:#8a5d00;--blue:#06c}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}header{background:#151515;color:#fff;padding:28px max(24px,calc((100% - 1320px)/2))}header h1{margin:0 0 6px;font-size:28px}header p{margin:3px 0;color:#d2d2d2}main{max-width:1320px;margin:24px auto;padding:0 24px}section{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:0 0 20px;padding:20px}h2{font-size:20px;margin:0 0 16px;border-bottom:1px solid var(--line);padding-bottom:10px}h3{margin:22px 0 8px}.cards{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:12px;margin-bottom:20px}.card{background:#fff;border:1px solid var(--line);border-radius:8px;padding:16px}.card strong{display:block;font-size:26px}.muted,.empty{color:var(--muted)}.badge{display:inline-block;border-radius:12px;color:#fff;font-size:11px;font-weight:700;padding:2px 9px;white-space:nowrap}.pass{background:var(--green)}.fail{background:var(--red)}.warn{background:var(--amber)}.info{background:var(--blue)}.table-wrap{overflow:auto}table{width:100%;border-collapse:collapse}th,td{border-bottom:1px solid #e7e7e7;padding:9px 10px;text-align:left;vertical-align:top}th{background:#f5f5f5;font-size:12px;text-transform:uppercase;letter-spacing:.03em}code{background:#f0f0f0;border-radius:3px;padding:2px 4px}@media(max-width:760px){.cards{grid-template-columns:repeat(2,1fr)}}
</style></head><body><header><h1>Migration Toolkit for Virtualization Audit</h1><p>Cluster context: $(html_escape "$CURRENT_CONTEXT")</p><p>Generated: $(html_escape "$GENERATED_AT") | OpenShift: $(html_escape "$OPENSHIFT_VERSION") | API: $(html_escape "$SERVER")</p></header><main>
<div class="cards"><div class="card"><span>Overall</span><strong>$(status_badge "$overall")</strong></div><div class="card"><span>Passed checks</span><strong>$pass_count</strong></div><div class="card"><span>Warnings</span><strong>$warn_count</strong></div><div class="card"><span>Failed checks</span><strong>$fail_count</strong></div></div>
<section><h2>Executive findings</h2>
EOF
    render_table "$FINDINGS" 'Status|Component|Finding' 0
    printf '</section><section><h2>Operator and workloads</h2><h3>ClusterServiceVersions</h3>\n'
    render_table "$CSV_ROWS" 'Namespace|CSV|Version|Phase' 3
    printf '<h3>Deployments</h3>\n'
    render_table "$DEPLOYMENT_ROWS" 'Namespace|Deployment|Desired|Ready|Available'
    printf '</section><section><h2>Source providers</h2>\n'
    render_table "$PROVIDER_ROWS" 'Namespace|Provider|Type|Health|Condition details' 3
    printf '</section><section><h2>Network mappings</h2>\n'
    render_table "$NETWORK_ROWS" 'NetworkMap|Entry|vCenter source|OpenShift destination|Type|Validation|Details' 5
    printf '</section><section><h2>Storage mappings</h2>\n'
    render_table "$STORAGE_ROWS" 'StorageMap|Entry|vCenter datastore|OpenShift StorageClass|Validation|Details' 4
    printf '</section><section><h2>Live vCenter inventory</h2>\n'
    if [[ -s "$INVENTORY_INDEX" ]]; then
      while IFS=$'\t' read -r provider kind verified message file; do
        printf '<h3>%s — %s</h3><p>%s %s</p>\n' "$(html_escape "$provider")" "$(html_escape "$kind")" "$(status_badge "$verified")" "$(html_escape "$message")"
        local inventory_tsv="$CLUSTER_DIR/inventory/.table-$(safe_name "$provider")-$kind.tsv"
        jq -r '.[]? | [(.name // .object.name // .path // "Unknown"), (.id // .uid // .object.id // .moref // .moRef // "")] | @tsv' "$file" >"$inventory_tsv"
        render_table "$inventory_tsv" 'Name|ID'
      done <"$INVENTORY_INDEX"
    else
      printf '<p class="empty">No vCenter source provider was found.</p>'
    fi
    printf '</section><section><h2>Generated YAML files</h2><p class="muted">Kubernetes Secrets are intentionally excluded.</p>\n'
    sort -u "$YAML_FILES" >"$CLUSTER_DIR/.yaml-sorted.tsv"
    render_table "$CLUSTER_DIR/.yaml-sorted.tsv" 'Relative path'
    printf '</section></main></body></html>\n'
  } >"$CLUSTER_DIR/mtv-audit-report.html"
}

audit_cluster() {
  CURRENT_CONTEXT="$1"
  CLUSTER_DIR="$OUTPUT_DIR/$(safe_name "$CURRENT_CONTEXT")"
  mkdir -p "$CLUSTER_DIR/yaml" "$CLUSTER_DIR/inventory" "$CLUSTER_DIR/raw"
  FINDINGS="$CLUSTER_DIR/findings.tsv"
  YAML_FILES="$CLUSTER_DIR/yaml-files.tsv"
  CSV_ROWS="$CLUSTER_DIR/raw/csv.tsv"
  DEPLOYMENT_ROWS="$CLUSTER_DIR/raw/deployments.tsv"
  PROVIDER_ROWS="$CLUSTER_DIR/raw/providers.tsv"
  NETWORK_ROWS="$CLUSTER_DIR/raw/network-mappings.tsv"
  STORAGE_ROWS="$CLUSTER_DIR/raw/storage-mappings.tsv"
  INVENTORY_INDEX="$CLUSTER_DIR/raw/inventory-index.tsv"
  TMP_ERROR="$CLUSTER_DIR/raw/last-error.txt"
  SERVICES_JSON="$CLUSTER_DIR/raw/services.json"
  : >"$FINDINGS"; : >"$YAML_FILES"; : >"$CSV_ROWS"; : >"$DEPLOYMENT_ROWS"; : >"$PROVIDER_ROWS"; : >"$NETWORK_ROWS"; : >"$STORAGE_ROWS"; : >"$INVENTORY_INDEX"
  GENERATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  SERVER="$(oc_ctx whoami --show-server 2>"$TMP_ERROR" || true)"
  [[ -n "$SERVER" ]] || { echo "ERROR: cannot access context $CURRENT_CONTEXT: $(<"$TMP_ERROR")" >&2; return 1; }
  OPENSHIFT_VERSION="$(oc_ctx get clusterversion version -o json 2>/dev/null | jq -r '.status.desired.version // "Unknown"' || printf Unknown)"

  declare -A resource_map=(
    [forkliftcontrollers]="forkliftcontrollers.${MTV_GROUP}"
    [providers]="providers.${MTV_GROUP}"
    [networkmaps]="networkmaps.${MTV_GROUP}"
    [storagemaps]="storagemaps.${MTV_GROUP}"
  )
  local label resource json_file
  for label in forkliftcontrollers providers networkmaps storagemaps; do
    resource="${resource_map[$label]}"; json_file="$CLUSTER_DIR/raw/${label}.json"
    if ! oc_ctx get "$resource" -A -o json >"$json_file" 2>"$TMP_ERROR"; then
      printf '{"items":[]}\n' >"$json_file"
      finding "$([[ "$label" == forkliftcontrollers ]] && printf FAIL || printf WARN)" "$label" "Could not query $resource: $(<"$TMP_ERROR")"
    fi
    export_resource_set "$label" "$resource" "$json_file"
  done

  local missing_crds=()
  for resource in "${resource_map[@]}"; do
    oc_ctx get crd "$resource" >/dev/null 2>&1 || missing_crds+=("$resource")
  done
  if ((${#missing_crds[@]})); then
    finding FAIL "MTV operator" "Missing required CRDs: ${missing_crds[*]}"
  else
    finding PASS "MTV operator" "All required Forklift CRDs are installed"
  fi

  local csv_json="$CLUSTER_DIR/raw/csv.json"
  if oc_ctx get csv -A -o json >"$csv_json" 2>"$TMP_ERROR"; then
    jq -r '.items[]? | select((((.metadata.name // "") + " " + (.spec.displayName // "") + " " + ((.metadata.labels // {}) | tostring)) | ascii_downcase) | test("migration toolkit for virtualization|mtv-operator")) | [(.metadata.namespace // ""), .metadata.name, (.spec.version // ""), (.status.phase // "Unknown")] | @tsv' "$csv_json" >"$CSV_ROWS"
    if [[ ! -s "$CSV_ROWS" ]]; then finding WARN "MTV operator" "No MTV ClusterServiceVersion was identified"; fi
    while IFS=$'\t' read -r ns name version phase; do
      [[ "$phase" == Succeeded ]] && finding PASS "MTV operator" "CSV $ns/$name phase is $phase" || finding FAIL "MTV operator" "CSV $ns/$name phase is $phase"
    done <"$CSV_ROWS"
  else
    finding WARN "MTV operator" "Could not query ClusterServiceVersions: $(<"$TMP_ERROR")"
  fi

  local deployments_json="$CLUSTER_DIR/raw/deployments.json"
  if oc_ctx get deployments -A -o json >"$deployments_json" 2>"$TMP_ERROR"; then
    jq -r '.items[]? | select((((.metadata.namespace // "") + " " + (.metadata.name // "") + " " + ((.metadata.labels // {}) | tostring)) | ascii_downcase) | test("openshift-mtv|forklift|mtv-operator")) | [(.metadata.namespace // ""), .metadata.name, (.spec.replicas // 0), (.status.readyReplicas // 0), (.status.availableReplicas // 0)] | @tsv' "$deployments_json" >"$DEPLOYMENT_ROWS"
    [[ -s "$DEPLOYMENT_ROWS" ]] || finding FAIL "MTV workloads" "No MTV/Forklift deployments were found"
    while IFS=$'\t' read -r ns name desired ready available; do
      if ((desired > 0 && ready >= desired && available >= desired)); then
        finding PASS "MTV workloads" "Deployment $ns/$name: $ready/$desired ready, $available available"
      else
        finding FAIL "MTV workloads" "Deployment $ns/$name: $ready/$desired ready, $available available"
      fi
    done <"$DEPLOYMENT_ROWS"
  else
    finding WARN "MTV workloads" "Could not query deployments: $(<"$TMP_ERROR")"
  fi

  local controllers_json="$CLUSTER_DIR/raw/forkliftcontrollers.json"
  if [[ "$(jq '.items | length' "$controllers_json")" -eq 0 ]]; then
    finding FAIL "MTV operator" "No ForkliftController custom resource exists"
  fi
  while IFS= read -r encoded; do
    local object health detail ns name
    object="$(printf '%s' "$encoded" | base64 -d)"
    IFS=$'\t' read -r health detail < <(conditions_health "$object")
    ns="$(jq -r '.metadata.namespace // ""' <<<"$object")"; name="$(jq -r '.metadata.name // ""' <<<"$object")"
    finding "$health" "ForkliftController" "$ns/$name: $detail"
  done < <(jq -r '.items[]? | @base64' "$controllers_json")

  local providers_json="$CLUSTER_DIR/raw/providers.json"
  if [[ "$(jq '.items | length' "$providers_json")" -eq 0 ]]; then finding WARN Provider "No MTV Provider objects were found"; fi
  if ! oc_ctx get services -A -o json >"$SERVICES_JSON" 2>"$TMP_ERROR"; then
    printf '{"items":[]}\n' >"$SERVICES_JSON"; finding WARN Inventory "Could not list services: $(<"$TMP_ERROR")"
  fi
  while IFS= read -r encoded; do
    local object health detail ns name type uid provider_key network_file datastore_file
    object="$(printf '%s' "$encoded" | base64 -d)"
    IFS=$'\t' read -r health detail < <(conditions_health "$object")
    ns="$(jq -r '.metadata.namespace // ""' <<<"$object")"; name="$(jq -r '.metadata.name // ""' <<<"$object")"; type="$(jq -r '.spec.type // ""' <<<"$object")"; uid="$(jq -r '.metadata.uid // ""' <<<"$object")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(clean_field "$ns")" "$(clean_field "$name")" "$(clean_field "$type")" "$health" "$(clean_field "$detail")" >>"$PROVIDER_ROWS"
    finding "$health" Provider "$ns/$name: $detail"
    case "${type,,}" in
      vsphere|vcenter|vmware)
        provider_key="$ns/$name"; network_file="$CLUSTER_DIR/inventory/$(safe_name "$ns")__$(safe_name "$name")__networks.json"; datastore_file="$CLUSTER_DIR/inventory/$(safe_name "$ns")__$(safe_name "$name")__datastores.json"
        if $NO_VCENTER_INVENTORY; then
          printf '[]\n' >"$network_file"; printf '[]\n' >"$datastore_file"
          printf '%s\tnetworks\tNOT VERIFIED\t%s\t%s\n' "$provider_key" "Inventory lookup disabled by command-line option" "$network_file" >>"$INVENTORY_INDEX"
          printf '%s\tdatastores\tNOT VERIFIED\t%s\t%s\n' "$provider_key" "Inventory lookup disabled by command-line option" "$datastore_file" >>"$INVENTORY_INDEX"
          finding WARN "vCenter inventory" "$provider_key networks: inventory lookup disabled"
          finding WARN "vCenter inventory" "$provider_key datastores: inventory lookup disabled"
        else
          if inventory_query "$uid" "$type" networks "$network_file"; then
            printf '%s\tnetworks\tPASS\tLive inventory query succeeded\t%s\n' "$provider_key" "$network_file" >>"$INVENTORY_INDEX"
          else
            printf '%s\tnetworks\tNOT VERIFIED\tInventory service or supported endpoint was unavailable\t%s\n' "$provider_key" "$network_file" >>"$INVENTORY_INDEX"
            finding WARN "vCenter inventory" "$provider_key networks: inventory service or supported endpoint was unavailable"
          fi
          if inventory_query "$uid" "$type" datastores "$datastore_file"; then
            printf '%s\tdatastores\tPASS\tLive inventory query succeeded\t%s\n' "$provider_key" "$datastore_file" >>"$INVENTORY_INDEX"
          else
            printf '%s\tdatastores\tNOT VERIFIED\tInventory service or supported endpoint was unavailable\t%s\n' "$provider_key" "$datastore_file" >>"$INVENTORY_INDEX"
            finding WARN "vCenter inventory" "$provider_key datastores: inventory service or supported endpoint was unavailable"
          fi
        fi ;;
    esac
  done < <(jq -r '.items[]? | @base64' "$providers_json")

  local networkmaps_json="$CLUSTER_DIR/raw/networkmaps.json" storagemaps_json="$CLUSTER_DIR/raw/storagemaps.json"
  while IFS= read -r encoded; do
    local mapping map_ns map_name source_provider source_ns provider_exists inv_file inv_verified entry_count index entry source destination dtype dest_ns nad_name validation note
    mapping="$(printf '%s' "$encoded" | base64 -d)"; map_ns="$(jq -r '.metadata.namespace // ""' <<<"$mapping")"; map_name="$(jq -r '.metadata.name // ""' <<<"$mapping")"
    source_provider="$(jq -r '.spec.provider.source.name // ""' <<<"$mapping")"; source_ns="$(jq -r --arg ns "$map_ns" '.spec.provider.source.namespace // $ns' <<<"$mapping")"
    provider_exists="$(jq -r --arg ns "$source_ns" --arg name "$source_provider" '[.items[]? | select(.metadata.namespace==$ns and .metadata.name==$name)] | length' "$providers_json")"
    ((provider_exists > 0)) || finding FAIL NetworkMap "$map_ns/$map_name references missing source Provider $source_ns/$source_provider"
    entry_count="$(jq '.spec.map // [] | length' <<<"$mapping")"; ((entry_count > 0)) || finding WARN NetworkMap "$map_ns/$map_name has no mapping entries"
    inv_file="$CLUSTER_DIR/inventory/$(safe_name "$source_ns")__$(safe_name "$source_provider")__networks.json"
    inv_verified=false; grep -Fq "$source_ns/$source_provider"$'\tnetworks\tPASS\t' "$INVENTORY_INDEX" && inv_verified=true
    for ((index=0; index<entry_count; index++)); do
      entry="$(jq -c --argjson i "$index" '.spec.map[$i]' <<<"$mapping")"
      source="$(jq -r '.source.id // .source.name // .source.path // ""' <<<"$entry")"; destination="$(jq -r '.destination.name // .destination.id // ""' <<<"$entry")"; dtype="$(jq -r '.destination.type // "unspecified"' <<<"$entry")"
      validation=PASS; note="Mapping is structurally valid"
      if [[ -z "$source" || -z "$destination" ]]; then validation=FAIL; note="Source or destination is empty"
      elif $inv_verified && ! inventory_has "$inv_file" "$source"; then validation=FAIL; note="Source network was not found in the live vCenter inventory"
      elif ! $inv_verified; then validation="NOT VERIFIED"; note="Live vCenter inventory was unavailable"; fi
      if [[ "${dtype,,}" == multus || ( "$destination" == */* && "${dtype,,}" != pod ) ]]; then
        dest_ns="$(jq -r --arg ns "$map_ns" --arg d "$destination" '.destination.namespace // (if ($d|contains("/")) then ($d|split("/")[0]) else $ns end)' <<<"$entry")"; nad_name="${destination##*/}"
        if ! oc_ctx get network-attachment-definitions.k8s.cni.cncf.io "$nad_name" -n "$dest_ns" >/dev/null 2>&1; then validation=FAIL; note="Destination NetworkAttachmentDefinition $dest_ns/$nad_name does not exist"; fi
        export_destination network-attachment-definitions.k8s.cni.cncf.io "$nad_name" "$dest_ns" "$CLUSTER_DIR/yaml/destinations/networks/$(safe_name "$dest_ns")__$(safe_name "$nad_name").yaml"
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$map_ns/$map_name" "$((index+1))" "$(clean_field "$source")" "$(clean_field "$destination")" "$(clean_field "$dtype")" "$validation" "$note" >>"$NETWORK_ROWS"
      [[ "$validation" == "NOT VERIFIED" ]] && finding WARN NetworkMap "$map_ns/$map_name entry $((index+1)): $note" || finding "$validation" NetworkMap "$map_ns/$map_name entry $((index+1)): $note"
    done
  done < <(jq -r '.items[]? | @base64' "$networkmaps_json")

  while IFS= read -r encoded; do
    local mapping map_ns map_name source_provider source_ns provider_exists inv_file inv_verified entry_count index entry source storage_class validation note
    mapping="$(printf '%s' "$encoded" | base64 -d)"; map_ns="$(jq -r '.metadata.namespace // ""' <<<"$mapping")"; map_name="$(jq -r '.metadata.name // ""' <<<"$mapping")"
    source_provider="$(jq -r '.spec.provider.source.name // ""' <<<"$mapping")"; source_ns="$(jq -r --arg ns "$map_ns" '.spec.provider.source.namespace // $ns' <<<"$mapping")"
    provider_exists="$(jq -r --arg ns "$source_ns" --arg name "$source_provider" '[.items[]? | select(.metadata.namespace==$ns and .metadata.name==$name)] | length' "$providers_json")"
    ((provider_exists > 0)) || finding FAIL StorageMap "$map_ns/$map_name references missing source Provider $source_ns/$source_provider"
    entry_count="$(jq '.spec.map // [] | length' <<<"$mapping")"; ((entry_count > 0)) || finding WARN StorageMap "$map_ns/$map_name has no mapping entries"
    inv_file="$CLUSTER_DIR/inventory/$(safe_name "$source_ns")__$(safe_name "$source_provider")__datastores.json"
    inv_verified=false; grep -Fq "$source_ns/$source_provider"$'\tdatastores\tPASS\t' "$INVENTORY_INDEX" && inv_verified=true
    for ((index=0; index<entry_count; index++)); do
      entry="$(jq -c --argjson i "$index" '.spec.map[$i]' <<<"$mapping")"
      source="$(jq -r '.source.id // .source.name // .source.path // ""' <<<"$entry")"; storage_class="$(jq -r '.destination.storageClass // .destination.name // .destination.id // ""' <<<"$entry")"
      validation=PASS; note="Mapping is structurally valid and the destination StorageClass exists"
      if [[ -z "$source" || -z "$storage_class" ]]; then validation=FAIL; note="Source datastore or destination StorageClass is empty"
      elif ! oc_ctx get storageclasses.storage.k8s.io "$storage_class" >/dev/null 2>&1; then validation=FAIL; note="Destination StorageClass $storage_class does not exist"
      elif $inv_verified && ! inventory_has "$inv_file" "$source"; then validation=FAIL; note="Source datastore was not found in the live vCenter inventory"
      elif ! $inv_verified; then validation="NOT VERIFIED"; note="Live vCenter datastore inventory was unavailable; destination StorageClass exists"; fi
      [[ -n "$storage_class" ]] && export_destination storageclasses.storage.k8s.io "$storage_class" "" "$CLUSTER_DIR/yaml/destinations/storageclasses/$(safe_name "$storage_class").yaml"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$map_ns/$map_name" "$((index+1))" "$(clean_field "$source")" "$(clean_field "$storage_class")" "$validation" "$note" >>"$STORAGE_ROWS"
      [[ "$validation" == "NOT VERIFIED" ]] && finding WARN StorageMap "$map_ns/$map_name entry $((index+1)): $note" || finding "$validation" StorageMap "$map_ns/$map_name entry $((index+1)): $note"
    done
  done < <(jq -r '.items[]? | @base64' "$storagemaps_json")

  render_cluster_report
  jq -n --arg cluster "$CURRENT_CONTEXT" --arg generated "$GENERATED_AT" --arg server "$SERVER" --arg version "$OPENSHIFT_VERSION" \
    --rawfile findings "$FINDINGS" '{cluster:$cluster,generatedAt:$generated,server:$server,openshiftVersion:$version,findingsTSV:$findings}' >"$CLUSTER_DIR/audit-summary.json"
  printf '%s\t%s\t%s\t%s\t%s\n' "$CURRENT_CONTEXT" "$REPORT_STATUS" "$REPORT_FAILURES" "$REPORT_WARNINGS" "$OPENSHIFT_VERSION" >>"$INDEX_ROWS"
  echo "  Report: $CLUSTER_DIR/mtv-audit-report.html"
  [[ "$REPORT_STATUS" == FAIL ]] && return 2
  return 0
}

INDEX_ROWS="$OUTPUT_DIR/.index-rows.tsv"
: >"$INDEX_ROWS"
fatal_count=0
failed_count=0
for context in "${CONTEXTS[@]}"; do
  echo "Auditing context: $context"
  audit_cluster "$context"
  cluster_rc=$?
  case "$cluster_rc" in
    0) ;;
    2) ((failed_count++)) || true ;;
    *) ((fatal_count++)) || true ;;
  esac
done

{
  cat <<'EOF'
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>MTV Multi-cluster Audit</title><style>body{font:14px system-ui;margin:32px;color:#151515}table{border-collapse:collapse;width:100%;max-width:1000px}th,td{border-bottom:1px solid #ddd;padding:10px;text-align:left}th{background:#f5f5f5}.badge{color:#fff;border-radius:12px;padding:3px 10px;font-weight:700;font-size:11px}.pass{background:#3e8635}.fail{background:#c9190b}.warn{background:#8a5d00}.info{background:#06c}a{color:#06c}</style></head><body><h1>MTV Multi-cluster Audit</h1><table><thead><tr><th>Cluster</th><th>Overall</th><th>Failures</th><th>Warnings</th><th>OpenShift</th></tr></thead><tbody>
EOF
  while IFS=$'\t' read -r context status failures warnings version; do
    printf '<tr><td><a href="%s/mtv-audit-report.html">%s</a></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' "$(safe_name "$context")" "$(html_escape "$context")" "$(status_badge "$status")" "$failures" "$warnings" "$(html_escape "$version")"
  done <"$INDEX_ROWS"
  printf '</tbody></table></body></html>\n'
} >"$OUTPUT_DIR/index.html"

echo "Index: $OUTPUT_DIR/index.html"
((fatal_count > 0)) && exit 1
((failed_count > 0)) && exit 2
exit 0