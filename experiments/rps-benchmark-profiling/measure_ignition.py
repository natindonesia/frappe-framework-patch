#!/usr/bin/env python3
"""
measure_ignition.py
Measures the cold-start ignition latency of Frappe web pods.
Instruments pod scheduling, container start, readiness probe pass, and first HTTP request.
"""

import subprocess
import json
import time
import argparse
from datetime import datetime

NAMESPACE = "default"

def parse_iso(ts_str):
    if not ts_str:
        return None
    cleaned = ts_str.rstrip("Z")
    if "." in cleaned:
        dt, frac = cleaned.split(".")
        frac = frac[:6]
        return datetime.fromisoformat(f"{dt}.{frac}")
    return datetime.fromisoformat(cleaned)

def run_cmd(cmd):
    return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()

def measure_pod(name, namespace=NAMESPACE, site="frappe.local"):
    out = run_cmd(f"kubectl get pod {name} -n {namespace} -o json")
    data = json.loads(out)
    
    metadata = data.get("metadata", {})
    status = data.get("status", {})
    
    created_ts = parse_iso(metadata.get("creationTimestamp"))
    conditions = {c["type"]: parse_iso(c["lastTransitionTime"]) for c in status.get("conditions", [])}
    
    scheduled_ts = conditions.get("PodScheduled")
    ready_ts = conditions.get("Ready")
    
    started_ts = None
    container_statuses = status.get("containerStatuses", [])
    for cs in container_statuses:
        state = cs.get("state", {})
        if "running" in state:
            started_ts = parse_iso(state["running"].get("startedAt"))
            break
            
    print(f"\n[*] Cold Start Latency Breakdown for Pod {name}:")
    print(f"      Created at:   {created_ts.isoformat()}")
    if scheduled_ts:
        print(f"      Scheduled at: {scheduled_ts.isoformat()}  (+{(scheduled_ts - created_ts).total_seconds():.3f}s)")
    if started_ts:
        print(f"      Started at:   {started_ts.isoformat()}  (+{(started_ts - created_ts).total_seconds():.3f}s)")
    if ready_ts:
        print(f"      Ready at:     {ready_ts.isoformat()}  (+{(ready_ts - created_ts).total_seconds():.3f}s)")
        
    curl_time_raw = run_cmd(f"kubectl exec -n {namespace} {name} -- curl -s -w '%{{time_total}}' -o /dev/null http://127.0.0.1:8000/api/method/ping -H 'Host: {site}'")
    curl_sec = float(curl_time_raw)
    print(f"      First HTTP 200 latency: {curl_sec * 1000:.1f}ms")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("pod_name", help="Name of the pod to measure")
    parser.add_argument("--namespace", default=NAMESPACE, help="Kubernetes namespace")
    parser.add_argument("--site", default="frappe.local", help="Frappe site hostname")
    args = parser.parse_args()
    measure_pod(args.pod_name, namespace=args.namespace, site=args.site)
