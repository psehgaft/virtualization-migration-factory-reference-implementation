#!/usr/bin/env python3
"""Audit Migration Toolkit for Virtualization (MTV) on OpenShift clusters.

The script is read-only.  It uses the local ``oc`` login/configuration, exports
MTV custom resources as YAML, validates mappings, and writes an English HTML
report.  It never exports Kubernetes Secret objects.
"""

from __future__ import annotations

import argparse
import datetime as dt
import html
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Iterable
from urllib.parse import quote


MTV_GROUP = "forklift.konveyor.io"
# Set MTV_AUDIT_CONTEXT or replace CHANGEME to pin a default kubeconfig context.
DEFAULT_CONTEXT = os.getenv("MTV_AUDIT_CONTEXT", "CHANGEME")
RESOURCES = {
    "forkliftcontrollers": f"forkliftcontrollers.{MTV_GROUP}",
    "providers": f"providers.{MTV_GROUP}",
    "networkmaps": f"networkmaps.{MTV_GROUP}",
    "storagemaps": f"storagemaps.{MTV_GROUP}",
}
GOOD_CONDITIONS = ("ready", "succeeded", "connected", "inventorycreated")
BAD_CONDITIONS = ("failed", "error", "degraded")


def safe_name(value: str) -> str:
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value.strip())
    return value[:180] or "unnamed"


def dig(obj: Any, *path: str, default: Any = None) -> Any:
    cur = obj
    for key in path:
        if not isinstance(cur, dict) or key not in cur:
            return default
        cur = cur[key]
    return cur


def first_value(obj: dict[str, Any], paths: Iterable[tuple[str, ...]], default: str = "") -> str:
    for path in paths:
        value = dig(obj, *path)
        if value is not None and str(value).strip():
            return str(value)
    return default


def as_list(payload: Any) -> list[Any]:
    if isinstance(payload, list):
        return payload
    if isinstance(payload, dict):
        for key in ("items", "resources", "data"):
            if isinstance(payload.get(key), list):
                return payload[key]
    return []


class Oc:
    def __init__(self, context: str, timeout: int):
        self.context = context
        self.timeout = timeout

    def run(self, *args: str, check: bool = False) -> subprocess.CompletedProcess[str]:
        cmd = ["oc", "--context", self.context, "--request-timeout", f"{self.timeout}s", *args]
        try:
            result = subprocess.run(cmd, text=True, capture_output=True, timeout=self.timeout + 10)
        except subprocess.TimeoutExpired as exc:
            result = subprocess.CompletedProcess(cmd, 124, exc.stdout or "", f"Command timed out after {self.timeout}s")
        if check and result.returncode:
            raise RuntimeError(result.stderr.strip() or "oc command failed")
        return result

    def json(self, *args: str) -> tuple[Any | None, str]:
        result = self.run(*args)
        if result.returncode:
            return None, result.stderr.strip()
        try:
            return json.loads(result.stdout), ""
        except json.JSONDecodeError as exc:
            return None, f"Invalid JSON returned by oc: {exc}"


def add_finding(audit: dict[str, Any], severity: str, component: str, message: str) -> None:
    audit["findings"].append({"severity": severity, "component": component, "message": message})


def conditions_health(obj: dict[str, Any]) -> tuple[str, str]:
    conditions = dig(obj, "status", "conditions", default=[]) or []
    if not conditions:
        return "WARN", "No status conditions are published"
    positives: list[str] = []
    negatives: list[str] = []
    for condition in conditions:
        ctype = str(condition.get("type", "Unknown"))
        status = str(condition.get("status", "Unknown")).lower()
        reason = str(condition.get("reason", "")).strip()
        normalized = ctype.lower().replace("_", "").replace("-", "")
        label = f"{ctype}={condition.get('status', 'Unknown')}" + (f" ({reason})" if reason else "")
        if (status == "true" and any(x in normalized for x in BAD_CONDITIONS)) or (
            status == "false" and any(x in normalized for x in GOOD_CONDITIONS)
        ):
            negatives.append(label)
        if status == "true" and any(x in normalized for x in GOOD_CONDITIONS):
            positives.append(label)
    if negatives:
        return "FAIL", "; ".join(negatives)
    if positives:
        return "PASS", "; ".join(positives)
    rendered = "; ".join(f"{c.get('type', 'Unknown')}={c.get('status', 'Unknown')}" for c in conditions)
    return "WARN", rendered or "Conditions do not expose a recognizable ready state"


def export_resource(oc: Oc, resource: str, item: dict[str, Any], target: Path) -> str | None:
    meta = item.get("metadata", {})
    namespace = meta.get("namespace")
    name = meta.get("name")
    if not name:
        return None
    args = ["get", resource, name]
    if namespace:
        args += ["-n", namespace]
    args += ["-o", "yaml", "--show-managed-fields=false"]
    result = oc.run(*args)
    if result.returncode:
        return result.stderr.strip() or "YAML export failed"
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(result.stdout, encoding="utf-8")
    return None


def export_all_yaml(oc: Oc, key: str, items: list[dict[str, Any]], cluster_dir: Path, audit: dict[str, Any]) -> None:
    resource = RESOURCES[key]
    if not items:
        return
    folder = cluster_dir / "yaml" / key
    for item in items:
        meta = item.get("metadata", {})
        ns = meta.get("namespace", "cluster")
        name = meta.get("name", "unnamed")
        path = folder / f"{safe_name(ns)}__{safe_name(name)}.yaml"
        error = export_resource(oc, resource, item, path)
        if error:
            add_finding(audit, "WARN", "YAML export", f"Could not export {key}/{ns}/{name}: {error}")
        else:
            audit["yaml_files"].append(str(path.relative_to(cluster_dir)))
    bulk = oc.run("get", resource, "-A", "-o", "yaml", "--show-managed-fields=false")
    if bulk.returncode == 0:
        path = cluster_dir / "yaml" / f"all-{key}.yaml"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(bulk.stdout, encoding="utf-8")
        audit["yaml_files"].append(str(path.relative_to(cluster_dir)))


def export_destination_yaml(oc: Oc, resource: str, name: str, namespace: str | None, target: Path, cluster_dir: Path, audit: dict[str, Any]) -> None:
    args = ["get", resource, name]
    if namespace:
        args += ["-n", namespace]
    args += ["-o", "yaml", "--show-managed-fields=false"]
    result = oc.run(*args)
    if result.returncode:
        add_finding(audit, "WARN", "YAML export", f"Could not export destination {resource}/{namespace or 'cluster'}/{name}: {result.stderr.strip()}")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(result.stdout, encoding="utf-8")
    audit["yaml_files"].append(str(target.relative_to(cluster_dir)))


def get_namespaced_items(oc: Oc, resource: str) -> tuple[list[dict[str, Any]], str]:
    payload, error = oc.json("get", resource, "-A", "-o", "json")
    if payload is None:
        return [], error
    return [x for x in payload.get("items", []) if isinstance(x, dict)], ""


def object_ref(ref: Any, default_ns: str) -> tuple[str, str]:
    if not isinstance(ref, dict):
        return "", default_ns
    return str(ref.get("name", "")), str(ref.get("namespace") or default_ns)


def inventory_aliases(item: Any) -> set[str]:
    aliases: set[str] = set()
    wanted = {"id", "name", "uid", "path", "moref", "moRef", "objectid", "objectID"}

    def walk(value: Any, key: str = "", depth: int = 0) -> None:
        if depth > 5:
            return
        if isinstance(value, dict):
            for k, v in value.items():
                walk(v, k, depth + 1)
        elif isinstance(value, list):
            for v in value[:10000]:
                walk(v, key, depth + 1)
        elif key in wanted and value is not None:
            aliases.add(str(value).strip().lower())

    walk(item)
    return {x for x in aliases if x}


def inventory_display(item: Any) -> tuple[str, str]:
    if not isinstance(item, dict):
        return str(item), ""
    name = first_value(item, [("name",), ("object", "name"), ("path",)], "Unknown")
    ident = first_value(item, [("id",), ("uid",), ("object", "id"), ("moref",), ("moRef",)], "")
    return name, ident


def query_inventory(oc: Oc, services: list[dict[str, Any]], provider: dict[str, Any], kind: str) -> tuple[list[Any], str]:
    meta = provider.get("metadata", {})
    uid = str(meta.get("uid", ""))
    ptype = str(dig(provider, "spec", "type", default="vsphere")).lower()
    ptype = {"vcenter": "vsphere", "vmware": "vsphere"}.get(ptype, ptype)
    if not uid:
        return [], "Provider UID is missing"
    endpoints = [
        f"/providers/{quote(ptype)}/{quote(uid)}/{kind}",
        f"/providers/{quote(uid)}/inventory/{kind}",
        f"/providers/{quote(uid)}/{kind}",
    ]
    errors: list[str] = []
    candidates = [s for s in services if "inventory" in str(dig(s, "metadata", "name", default="")).lower()]
    for service in candidates:
        ns = dig(service, "metadata", "namespace", default="")
        name = dig(service, "metadata", "name", default="")
        ports = dig(service, "spec", "ports", default=[]) or []
        tokens: list[str] = []
        for port in ports:
            for token in (port.get("name"), port.get("port")):
                if token is not None and str(token) not in tokens:
                    tokens.append(str(token))
        if not tokens:
            tokens = ["80"]
        for token in tokens:
            prefixes = [
                f"/api/v1/namespaces/{quote(ns)}/services/http:{quote(name)}:{quote(token)}/proxy",
                f"/api/v1/namespaces/{quote(ns)}/services/{quote(name)}:{quote(token)}/proxy",
            ]
            for prefix in prefixes:
                for endpoint in endpoints:
                    result = oc.run("get", "--raw", prefix + endpoint)
                    if result.returncode == 0:
                        try:
                            payload = json.loads(result.stdout)
                            rows = as_list(payload)
                            if rows or isinstance(payload, (list, dict)):
                                return rows, ""
                        except json.JSONDecodeError:
                            pass
                    if result.stderr.strip():
                        errors.append(result.stderr.strip().splitlines()[-1])
    if not candidates:
        return [], "No inventory service was found"
    concise = errors[-1] if errors else "No supported inventory endpoint returned JSON"
    return [], concise


def audit_operator(oc: Oc, audit: dict[str, Any], namespaces: set[str]) -> None:
    crds, error = oc.json("get", "crd", "-o", "json")
    names = {dig(x, "metadata", "name", default="") for x in (crds or {}).get("items", [])}
    required = set(RESOURCES.values())
    missing = sorted(required - names)
    if missing:
        add_finding(audit, "FAIL", "MTV operator", "Missing required CRDs: " + ", ".join(missing))
    else:
        add_finding(audit, "PASS", "MTV operator", "All required Forklift CRDs are installed")
    if error:
        add_finding(audit, "WARN", "MTV operator", f"CRD discovery warning: {error}")

    csvs, csv_error = oc.json("get", "csv", "-A", "-o", "json")
    matched_csvs = []
    for item in (csvs or {}).get("items", []):
        text = " ".join([
            str(dig(item, "metadata", "name", default="")),
            str(dig(item, "metadata", "labels", "operators.coreos.com/mtv-operator.openshift-mtv", default="")),
            str(dig(item, "spec", "displayName", default="")),
        ]).lower()
        if "migration toolkit for virtualization" in text or "mtv-operator" in text:
            matched_csvs.append(item)
    audit["csvs"] = [{
        "namespace": dig(x, "metadata", "namespace", default=""),
        "name": dig(x, "metadata", "name", default=""),
        "phase": dig(x, "status", "phase", default="Unknown"),
        "version": dig(x, "spec", "version", default=""),
    } for x in matched_csvs]
    if not matched_csvs:
        add_finding(audit, "WARN", "MTV operator", "No MTV ClusterServiceVersion was identified (the operator might use a different label/name)")
    for row in audit["csvs"]:
        level = "PASS" if row["phase"] == "Succeeded" else "FAIL"
        add_finding(audit, level, "MTV operator", f"CSV {row['namespace']}/{row['name']} phase is {row['phase']}")
        namespaces.add(row["namespace"])
    if csv_error:
        add_finding(audit, "WARN", "MTV operator", f"CSV query warning: {csv_error}")

    deployments, dep_error = oc.json("get", "deployments", "-A", "-o", "json")
    operator_deployments = []
    for dep in (deployments or {}).get("items", []):
        ns = dig(dep, "metadata", "namespace", default="")
        name = dig(dep, "metadata", "name", default="")
        labels = json.dumps(dig(dep, "metadata", "labels", default={}), sort_keys=True).lower()
        if ns in namespaces or "forklift" in name.lower() or "mtv-operator" in labels:
            desired = int(dig(dep, "spec", "replicas", default=1) or 0)
            ready = int(dig(dep, "status", "readyReplicas", default=0) or 0)
            available = int(dig(dep, "status", "availableReplicas", default=0) or 0)
            operator_deployments.append({"namespace": ns, "name": name, "desired": desired, "ready": ready, "available": available})
    audit["deployments"] = operator_deployments
    if not operator_deployments:
        add_finding(audit, "FAIL", "MTV workloads", "No MTV/Forklift deployments were found")
    for dep in operator_deployments:
        ok = dep["desired"] > 0 and dep["ready"] >= dep["desired"] and dep["available"] >= dep["desired"]
        add_finding(audit, "PASS" if ok else "FAIL", "MTV workloads", f"Deployment {dep['namespace']}/{dep['name']}: {dep['ready']}/{dep['desired']} ready, {dep['available']} available")
    if dep_error:
        add_finding(audit, "WARN", "MTV workloads", f"Deployment query warning: {dep_error}")


def mapping_source_key(entry: dict[str, Any]) -> str:
    return first_value(entry, [("source", "id"), ("source", "name"), ("source", "path")])


def validate_maps(audit: dict[str, Any], providers_by_ref: dict[tuple[str, str], dict[str, Any]], storage_classes: set[str], nads: set[tuple[str, str]]) -> None:
    inventories = audit["inventory"]
    for obj in audit["networkmaps"]:
        meta = obj.get("metadata", {})
        ns, name = meta.get("namespace", ""), meta.get("name", "")
        source_name, source_ns = object_ref(dig(obj, "spec", "provider", "source", default={}), ns)
        provider = providers_by_ref.get((source_ns, source_name))
        inv_key = f"{source_ns}/{source_name}"
        inv_rows = inventories.get(inv_key, {}).get("networks", [])
        inv_verified = inventories.get(inv_key, {}).get("networks_verified", False)
        aliases = set().union(*(inventory_aliases(x) for x in inv_rows)) if inv_rows else set()
        entries = dig(obj, "spec", "map", default=[]) or []
        if not provider:
            add_finding(audit, "FAIL", "NetworkMap", f"{ns}/{name} references missing source Provider {source_ns}/{source_name}")
        if not entries:
            add_finding(audit, "WARN", "NetworkMap", f"{ns}/{name} has no mapping entries")
        for index, entry in enumerate(entries, 1):
            src = mapping_source_key(entry)
            dest = entry.get("destination", {}) if isinstance(entry, dict) else {}
            dest_type = str(dest.get("type", "")).lower()
            dest_name = str(dest.get("name") or dest.get("id") or "")
            status, note = "PASS", "Mapping is structurally valid"
            if not src or not dest_name:
                status, note = "FAIL", "Source or destination is empty"
            elif inv_verified and src.lower() not in aliases:
                status, note = "FAIL", "Source network was not found in the live vCenter inventory"
            elif not inv_verified:
                status, note = "NOT VERIFIED", "Live vCenter inventory was unavailable"
            if dest_type == "multus" or ("/" in dest_name and dest_type != "pod"):
                dest_ns = str(dest.get("namespace") or (dest_name.split("/", 1)[0] if "/" in dest_name else ns))
                nad_name = dest_name.split("/", 1)[-1]
                if (dest_ns, nad_name) not in nads:
                    status, note = "FAIL", f"Destination NetworkAttachmentDefinition {dest_ns}/{nad_name} does not exist"
            audit["network_rows"].append({"map": f"{ns}/{name}", "entry": index, "source": src, "destination": dest_name, "type": dest_type or "unspecified", "status": status, "note": note})
            add_finding(audit, "WARN" if status == "NOT VERIFIED" else status, "NetworkMap", f"{ns}/{name} entry {index}: {note}")

    for obj in audit["storagemaps"]:
        meta = obj.get("metadata", {})
        ns, name = meta.get("namespace", ""), meta.get("name", "")
        source_name, source_ns = object_ref(dig(obj, "spec", "provider", "source", default={}), ns)
        provider = providers_by_ref.get((source_ns, source_name))
        inv_key = f"{source_ns}/{source_name}"
        inv_rows = inventories.get(inv_key, {}).get("datastores", [])
        inv_verified = inventories.get(inv_key, {}).get("datastores_verified", False)
        aliases = set().union(*(inventory_aliases(x) for x in inv_rows)) if inv_rows else set()
        entries = dig(obj, "spec", "map", default=[]) or []
        if not provider:
            add_finding(audit, "FAIL", "StorageMap", f"{ns}/{name} references missing source Provider {source_ns}/{source_name}")
        if not entries:
            add_finding(audit, "WARN", "StorageMap", f"{ns}/{name} has no mapping entries")
        for index, entry in enumerate(entries, 1):
            src = mapping_source_key(entry)
            dest = entry.get("destination", {}) if isinstance(entry, dict) else {}
            storage_class = str(dest.get("storageClass") or dest.get("name") or dest.get("id") or "")
            status, note = "PASS", "Mapping is structurally valid and the destination StorageClass exists"
            if not src or not storage_class:
                status, note = "FAIL", "Source datastore or destination StorageClass is empty"
            elif storage_class not in storage_classes:
                status, note = "FAIL", f"Destination StorageClass {storage_class} does not exist"
            elif inv_verified and src.lower() not in aliases:
                status, note = "FAIL", "Source datastore was not found in the live vCenter inventory"
            elif not inv_verified:
                status, note = "NOT VERIFIED", "Live vCenter datastore inventory was unavailable; destination StorageClass exists"
            audit["storage_rows"].append({"map": f"{ns}/{name}", "entry": index, "source": src, "storage_class": storage_class, "status": status, "note": note})
            add_finding(audit, "WARN" if status == "NOT VERIFIED" else status, "StorageMap", f"{ns}/{name} entry {index}: {note}")


def esc(value: Any) -> str:
    return html.escape(str(value if value is not None else ""))


def badge(status: str) -> str:
    css = {"PASS": "pass", "FAIL": "fail", "WARN": "warn", "NOT VERIFIED": "warn"}.get(status, "info")
    return f'<span class="badge {css}">{esc(status)}</span>'


def table(headers: list[str], rows: list[list[Any]], status_col: int | None = None) -> str:
    if not rows:
        return '<p class="empty">No items found.</p>'
    head = "".join(f"<th>{esc(x)}</th>" for x in headers)
    body = []
    for row in rows:
        cells = []
        for i, value in enumerate(row):
            cells.append(f"<td>{badge(str(value)) if i == status_col else esc(value)}</td>")
        body.append("<tr>" + "".join(cells) + "</tr>")
    return f'<div class="table-wrap"><table><thead><tr>{head}</tr></thead><tbody>{"".join(body)}</tbody></table></div>'


def render_cluster_report(audit: dict[str, Any], path: Path) -> None:
    counts = {s: sum(1 for x in audit["findings"] if x["severity"] == s) for s in ("PASS", "WARN", "FAIL")}
    provider_rows = []
    for p in audit["providers"]:
        meta = p.get("metadata", {})
        state, detail = conditions_health(p)
        provider_rows.append([meta.get("namespace", ""), meta.get("name", ""), dig(p, "spec", "type", default=""), state, detail])
    network_rows = [[x["map"], x["entry"], x["source"], x["destination"], x["type"], x["status"], x["note"]] for x in audit["network_rows"]]
    storage_rows = [[x["map"], x["entry"], x["source"], x["storage_class"], x["status"], x["note"]] for x in audit["storage_rows"]]
    inventory_html = []
    for provider, inv in sorted(audit["inventory"].items()):
        network_items = [[*inventory_display(x)] for x in inv.get("networks", [])]
        datastore_items = [[*inventory_display(x)] for x in inv.get("datastores", [])]
        inventory_html.append(f"<h3>{esc(provider)}</h3><p>{badge('PASS' if inv.get('networks_verified') else 'NOT VERIFIED')} Networks — {esc(inv.get('networks_error', ''))}</p>{table(['Network', 'ID'], network_items)}<p>{badge('PASS' if inv.get('datastores_verified') else 'NOT VERIFIED')} Datastores — {esc(inv.get('datastores_error', ''))}</p>{table(['Datastore', 'ID'], datastore_items)}")
    finding_rows = [[x["severity"], x["component"], x["message"]] for x in audit["findings"]]
    csv_rows = [[x["namespace"], x["name"], x["version"], x["phase"]] for x in audit["csvs"]]
    dep_rows = [[x["namespace"], x["name"], x["desired"], x["ready"], x["available"]] for x in audit["deployments"]]
    yaml_rows = [[x] for x in sorted(audit["yaml_files"])]
    overall = "FAIL" if counts["FAIL"] else ("WARN" if counts["WARN"] else "PASS")
    document = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>MTV Audit - {esc(audit['cluster'])}</title>
<style>
:root{{--bg:#f3f6f8;--card:#fff;--text:#151515;--muted:#6a6e73;--line:#d2d2d2;--red:#c9190b;--green:#3e8635;--amber:#f0ab00;--blue:#06c}}*{{box-sizing:border-box}}body{{margin:0;background:var(--bg);color:var(--text);font:14px/1.45 system-ui,-apple-system,Segoe UI,sans-serif}}header{{background:#151515;color:#fff;padding:28px max(24px,calc((100% - 1320px)/2))}}header h1{{margin:0 0 6px;font-size:28px}}header p{{margin:3px 0;color:#d2d2d2}}main{{max-width:1320px;margin:24px auto;padding:0 24px}}section{{background:var(--card);border:1px solid var(--line);border-radius:8px;margin:0 0 20px;padding:20px}}h2{{font-size:20px;margin:0 0 16px;border-bottom:1px solid var(--line);padding-bottom:10px}}h3{{margin:22px 0 8px}}.cards{{display:grid;grid-template-columns:repeat(4,minmax(140px,1fr));gap:12px;margin-bottom:20px}}.card{{background:#fff;border:1px solid var(--line);border-radius:8px;padding:16px}}.card strong{{display:block;font-size:26px}}.muted,.empty{{color:var(--muted)}}.badge{{display:inline-block;border-radius:12px;color:#fff;font-size:11px;font-weight:700;padding:2px 9px;white-space:nowrap}}.pass{{background:var(--green)}}.fail{{background:var(--red)}}.warn{{background:#8a5d00}}.info{{background:var(--blue)}}.table-wrap{{overflow:auto}}table{{width:100%;border-collapse:collapse}}th,td{{border-bottom:1px solid #e7e7e7;padding:9px 10px;text-align:left;vertical-align:top}}th{{background:#f5f5f5;font-size:12px;text-transform:uppercase;letter-spacing:.03em}}code{{background:#f0f0f0;border-radius:3px;padding:2px 4px}}@media(max-width:760px){{.cards{{grid-template-columns:repeat(2,1fr)}}}}
</style></head><body>
<header><h1>Migration Toolkit for Virtualization Audit</h1><p>Cluster context: {esc(audit['cluster'])}</p><p>Generated: {esc(audit['generated_at'])} | OpenShift: {esc(audit['openshift_version'])} | API: {esc(audit['server'])}</p></header>
<main>
<div class="cards"><div class="card"><span>Overall</span><strong>{badge(overall)}</strong></div><div class="card"><span>Passed checks</span><strong>{counts['PASS']}</strong></div><div class="card"><span>Warnings</span><strong>{counts['WARN']}</strong></div><div class="card"><span>Failed checks</span><strong>{counts['FAIL']}</strong></div></div>
<section><h2>Executive findings</h2>{table(['Status','Component','Finding'], finding_rows, 0)}</section>
<section><h2>Operator and workloads</h2><h3>ClusterServiceVersions</h3>{table(['Namespace','CSV','Version','Phase'], csv_rows, 3)}<h3>Deployments</h3>{table(['Namespace','Deployment','Desired','Ready','Available'], dep_rows)}</section>
<section><h2>Source providers</h2>{table(['Namespace','Provider','Type','Health','Condition details'], provider_rows, 3)}</section>
<section><h2>Network mappings</h2>{table(['NetworkMap','Entry','vCenter source','OpenShift destination','Type','Validation','Details'], network_rows, 5)}</section>
<section><h2>Storage mappings</h2>{table(['StorageMap','Entry','vCenter datastore','OpenShift StorageClass','Validation','Details'], storage_rows, 4)}</section>
<section><h2>Live vCenter inventory</h2>{''.join(inventory_html) if inventory_html else '<p class="empty">No vCenter source provider was found.</p>'}</section>
<section><h2>Generated YAML files</h2><p class="muted">Kubernetes Secrets are intentionally excluded.</p>{table(['Relative path'], yaml_rows)}</section>
</main></body></html>"""
    path.write_text(document, encoding="utf-8")


def audit_cluster(context: str, output_root: Path, timeout: int, disable_inventory: bool) -> tuple[dict[str, Any], Path]:
    oc = Oc(context, timeout)
    cluster_dir = output_root / safe_name(context)
    cluster_dir.mkdir(parents=True, exist_ok=True)
    audit: dict[str, Any] = {
        "cluster": context, "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(), "server": "Unknown",
        "openshift_version": "Unknown", "findings": [], "providers": [], "networkmaps": [], "storagemaps": [],
        "forkliftcontrollers": [], "network_rows": [], "storage_rows": [], "inventory": {}, "csvs": [],
        "deployments": [], "yaml_files": [],
    }
    server = oc.run("whoami", "--show-server")
    if server.returncode:
        raise RuntimeError(server.stderr.strip() or f"Cannot access context {context}")
    audit["server"] = server.stdout.strip()
    version, _ = oc.json("get", "clusterversion", "version", "-o", "json")
    audit["openshift_version"] = str(dig(version or {}, "status", "desired", "version", default="Unknown"))

    namespaces: set[str] = set()
    for key, resource in RESOURCES.items():
        items, error = get_namespaced_items(oc, resource)
        audit[key] = items
        namespaces.update(str(dig(x, "metadata", "namespace", default="")) for x in items)
        if error:
            level = "FAIL" if key == "forkliftcontrollers" else "WARN"
            add_finding(audit, level, key, f"Could not query {resource}: {error}")
        export_all_yaml(oc, key, items, cluster_dir, audit)

    audit_operator(oc, audit, namespaces)
    if not audit["forkliftcontrollers"]:
        add_finding(audit, "FAIL", "MTV operator", "No ForkliftController custom resource exists")
    for controller in audit["forkliftcontrollers"]:
        meta = controller.get("metadata", {})
        status, detail = conditions_health(controller)
        add_finding(audit, status, "ForkliftController", f"{meta.get('namespace','')}/{meta.get('name','')}: {detail}")

    providers_by_ref: dict[tuple[str, str], dict[str, Any]] = {}
    for provider in audit["providers"]:
        meta = provider.get("metadata", {})
        ref = (str(meta.get("namespace", "")), str(meta.get("name", "")))
        providers_by_ref[ref] = provider
        status, detail = conditions_health(provider)
        add_finding(audit, status, "Provider", f"{ref[0]}/{ref[1]}: {detail}")
    if not audit["providers"]:
        add_finding(audit, "WARN", "Provider", "No MTV Provider objects were found")

    services, service_error = oc.json("get", "services", "-A", "-o", "json")
    service_items = (services or {}).get("items", [])
    if service_error:
        add_finding(audit, "WARN", "Inventory", f"Could not list services: {service_error}")
    for (ns, name), provider in providers_by_ref.items():
        ptype = str(dig(provider, "spec", "type", default="")).lower()
        if ptype not in ("vsphere", "vcenter", "vmware"):
            continue
        inv: dict[str, Any] = {}
        for kind in ("networks", "datastores"):
            if disable_inventory:
                rows, error = [], "Inventory lookup disabled by command-line option"
            else:
                rows, error = query_inventory(oc, service_items, provider, kind)
            inv[kind] = rows
            inv[f"{kind}_verified"] = not bool(error)
            inv[f"{kind}_error"] = error
            if error:
                add_finding(audit, "WARN", "vCenter inventory", f"{ns}/{name} {kind}: {error}")
            inv_path = cluster_dir / "inventory" / f"{safe_name(ns)}__{safe_name(name)}__{kind}.json"
            inv_path.parent.mkdir(parents=True, exist_ok=True)
            inv_path.write_text(json.dumps(rows, indent=2, ensure_ascii=False), encoding="utf-8")
        audit["inventory"][f"{ns}/{name}"] = inv

    sc_payload, sc_error = oc.json("get", "storageclasses.storage.k8s.io", "-o", "json")
    storage_classes = {str(dig(x, "metadata", "name", default="")) for x in (sc_payload or {}).get("items", [])}
    if sc_error:
        add_finding(audit, "WARN", "Storage", f"Could not list StorageClasses: {sc_error}")
    nad_payload, nad_error = oc.json("get", "network-attachment-definitions.k8s.cni.cncf.io", "-A", "-o", "json")
    nads = {(str(dig(x, "metadata", "namespace", default="")), str(dig(x, "metadata", "name", default=""))) for x in (nad_payload or {}).get("items", [])}
    if nad_error:
        add_finding(audit, "WARN", "Network", f"Could not list NetworkAttachmentDefinitions: {nad_error}")
    validate_maps(audit, providers_by_ref, storage_classes, nads)

    # Export the OpenShift destination objects referenced by the mappings.
    referenced_nads: set[tuple[str, str]] = set()
    for mapping in audit["networkmaps"]:
        map_ns = str(dig(mapping, "metadata", "namespace", default=""))
        for entry in dig(mapping, "spec", "map", default=[]) or []:
            destination = entry.get("destination", {}) if isinstance(entry, dict) else {}
            dtype = str(destination.get("type", "")).lower()
            dname = str(destination.get("name") or destination.get("id") or "")
            if dtype == "multus" or ("/" in dname and dtype != "pod"):
                dns = str(destination.get("namespace") or (dname.split("/", 1)[0] if "/" in dname else map_ns))
                referenced_nads.add((dns, dname.split("/", 1)[-1]))
    referenced_scs = {row["storage_class"] for row in audit["storage_rows"] if row.get("storage_class")}
    for ns, name in sorted(referenced_nads):
        export_destination_yaml(oc, "network-attachment-definitions.k8s.cni.cncf.io", name, ns,
                                cluster_dir / "yaml" / "destinations" / "networks" / f"{safe_name(ns)}__{safe_name(name)}.yaml",
                                cluster_dir, audit)
    for name in sorted(referenced_scs):
        export_destination_yaml(oc, "storageclasses.storage.k8s.io", name, None,
                                cluster_dir / "yaml" / "destinations" / "storageclasses" / f"{safe_name(name)}.yaml",
                                cluster_dir, audit)

    report_path = cluster_dir / "mtv-audit-report.html"
    render_cluster_report(audit, report_path)
    (cluster_dir / "audit-data.json").write_text(json.dumps(audit, indent=2, ensure_ascii=False), encoding="utf-8")
    return audit, report_path


def render_index(results: list[tuple[dict[str, Any], Path]], output_root: Path) -> Path:
    rows = []
    for audit, report in results:
        failures = sum(1 for x in audit["findings"] if x["severity"] == "FAIL")
        warnings = sum(1 for x in audit["findings"] if x["severity"] == "WARN")
        overall = "FAIL" if failures else ("WARN" if warnings else "PASS")
        rel = report.relative_to(output_root).as_posix()
        rows.append(f'<tr><td><a href="{html.escape(rel)}">{esc(audit["cluster"])}</a></td><td>{badge(overall)}</td><td>{failures}</td><td>{warnings}</td><td>{esc(audit["openshift_version"])}</td></tr>')
    content = f"""<!doctype html><html lang="en"><head><meta charset="utf-8"><title>MTV Multi-cluster Audit</title><style>body{{font:14px system-ui;margin:32px;color:#151515}}table{{border-collapse:collapse;width:100%;max-width:1000px}}th,td{{border-bottom:1px solid #ddd;padding:10px;text-align:left}}th{{background:#f5f5f5}}.badge{{color:#fff;border-radius:12px;padding:3px 10px;font-weight:700;font-size:11px}}.pass{{background:#3e8635}}.fail{{background:#c9190b}}.warn{{background:#8a5d00}}a{{color:#06c}}</style></head><body><h1>MTV Multi-cluster Audit</h1><p>Generated {esc(dt.datetime.now(dt.timezone.utc).isoformat())}</p><table><thead><tr><th>Cluster</th><th>Overall</th><th>Failures</th><th>Warnings</th><th>OpenShift</th></tr></thead><tbody>{''.join(rows)}</tbody></table></body></html>"""
    path = output_root / "index.html"
    path.write_text(content, encoding="utf-8")
    return path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Audit MTV/Forklift on one or more OpenShift clusters and generate YAML plus English HTML reports.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--context", action="append", help="OpenShift kubeconfig context to audit; repeat for multiple clusters. Defaults to the current context.")
    group.add_argument("--all-contexts", action="store_true", help="Audit every context in the active kubeconfig.")
    parser.add_argument("--output-dir", default=f"mtv-audit-{dt.datetime.now().strftime('%Y%m%d-%H%M%S')}", help="Output directory.")
    parser.add_argument("--timeout", type=int, default=30, help="Timeout in seconds for each oc request (default: 30).")
    parser.add_argument("--no-vcenter-inventory", action="store_true", help="Skip best-effort live vCenter network/datastore inventory validation.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not shutil_which("oc"):
        print("ERROR: the oc executable was not found in PATH", file=sys.stderr)
        return 1
    if args.timeout < 5:
        print("ERROR: --timeout must be at least 5 seconds", file=sys.stderr)
        return 1
    if args.all_contexts:
        probe = subprocess.run(["oc", "config", "get-contexts", "-o", "name"], text=True, capture_output=True)
        contexts = [x.strip() for x in probe.stdout.splitlines() if x.strip()]
    elif args.context:
        contexts = args.context
    elif DEFAULT_CONTEXT != "CHANGEME":
        contexts = [DEFAULT_CONTEXT]
    else:
        probe = subprocess.run(["oc", "config", "current-context"], text=True, capture_output=True)
        contexts = [probe.stdout.strip()] if probe.returncode == 0 and probe.stdout.strip() else []
    if not contexts:
        print("ERROR: no OpenShift context was selected or found", file=sys.stderr)
        return 1
    output_root = Path(args.output_dir).expanduser().resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    results: list[tuple[dict[str, Any], Path]] = []
    fatal = False
    for context in contexts:
        print(f"Auditing context: {context}", flush=True)
        try:
            audit, report = audit_cluster(context, output_root, args.timeout, args.no_vcenter_inventory)
            results.append((audit, report))
            print(f"  Report: {report}")
        except Exception as exc:  # keep auditing the remaining clusters
            fatal = True
            print(f"  ERROR: {exc}", file=sys.stderr)
    if results:
        index = render_index(results, output_root)
        print(f"Index: {index}")
    has_failures = any(any(x["severity"] == "FAIL" for x in audit["findings"]) for audit, _ in results)
    return 1 if fatal and not results else (2 if has_failures or fatal else 0)


def shutil_which(command: str) -> str | None:
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(folder) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


if __name__ == "__main__":
    raise SystemExit(main())