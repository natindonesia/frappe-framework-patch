#!/usr/bin/env python3
"""
measure_ignition.py
Measures the exact millisecond breakdown of a Frappe web pod startup:
  Pod Created -> Scheduled -> Container Started -> Granian Listening -> Ready -> Endpoint Added -> First HTTP Request Served
"""

import sys
import time
import json
import subprocess
from datetime import datetime, timezone

NAMESPACE = "fayolex-working-staging"
DEPLOYMENT = "web"

def get_utc_now():
    return datetime.now(timezone.utc)

def parse_iso(ts_str):
    if not ts_str:
        return None
    # Support '2026-10-11T13:20:25Z' or fractional seconds
    ts_str = ts_str.rstrip("Z")
    if "." in ts_str:
        return datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc)
    return datetime.fromisoformat(ts_str).replace(tzinfo=timezone.utc)

def run_cmd(cmd):
    return subprocess.check_output(cmd, shell=True, text=True)

def main():
    print("=" * 80)
    print(" IGNITION LATENCY BENCHMARK: Measuring Pod Startup Lifecycle Breakdown")
    print(f" Namespace: {NAMESPACE} | Target: {DEPLOYMENT}")
    print("=" * 80)

    # 1. Inspect the existing running pod to get its exact historical breakdown
    print("[1/2] Analyzing existing live pod timestamps...")
    out = run_cmd(f"kubectl get pods -n {NAMESPACE} -l app=web -o json")
    data = json.loads(out)
    
    if not data.get("items"):
        print("[!] No running web pods found!")
        sys.exit(1)

    pod = data["items"][-1]
    name = pod["metadata"]["name"]
    created_ts = parse_iso(pod["metadata"]["creationTimestamp"])
    
    scheduled_ts = None
    ready_ts = None
    for c in pod.get("status", {}).get("conditions", []):
        if c["type"] == "PodScheduled":
            scheduled_ts = parse_iso(c["lastTransitionTime"])
        elif c["type"] == "Ready":
            ready_ts = parse_iso(c["lastTransitionTime"])
            
    c_status = pod.get("status", {}).get("containerStatuses", [{}])[0]
    started_ts = parse_iso(c_status.get("state", {}).get("running", {}).get("startedAt"))
    
    print(f"      Pod Name: {name}")
    print(f"      Created at:   {created_ts.isoformat()}")
    if scheduled_ts:
        print(f"      Scheduled at: {scheduled_ts.isoformat()}  (+{(scheduled_ts - created_ts).total_seconds():.3f}s)")
    if started_ts:
        print(f"      Started at:   {started_ts.isoformat()}  (+{(started_ts - created_ts).total_seconds():.3f}s)")
    if ready_ts:
        print(f"      Ready at:     {ready_ts.isoformat()}  (+{(ready_ts - created_ts).total_seconds():.3f}s)")

    # 2. Measure internal Frappe / Python initialization latency inside the container
    print("\n[2/2] Measuring internal application initialization stages inside container...")
    bench_script = '''
import time, json, os
t0 = time.time()
os.chdir("/home/frappe/frappe-bench/sites")
import frappe
t_import = time.time()
frappe.init("demo.fayolex.co.id")
t_init = time.time()
frappe.connect()
t_connect = time.time()
from frappe.handler import ping
p = ping()
t_ping = time.time()

print(json.dumps({
    "import_frappe_ms": round((t_import - t0) * 1000, 2),
    "site_init_ms": round((t_init - t_import) * 1000, 2),
    "db_connect_ms": round((t_connect - t_init) * 1000, 2),
    "ping_exec_ms": round((t_ping - t_connect) * 1000, 2),
    "total_app_boot_ms": round((t_ping - t0) * 1000, 2)
}))
'''
    res = subprocess.run(
        ["kubectl", "exec", "-n", NAMESPACE, name, "-c", "web", "--", "/home/frappe/frappe-bench/env/bin/python", "-c", bench_script],
        capture_output=True, text=True, check=True
    )
    app_timings = json.loads(res.stdout.strip())
    
    # Measure probe execution time via curl
    curl_time_raw = run_cmd(f"kubectl exec -n {NAMESPACE} {name} -- curl -s -w '%{{time_total}}' -o /dev/null http://127.0.0.1:8000/api/method/ping -H 'Host: demo.fayolex.co.id'")
    curl_time_ms = round(float(curl_time_raw.strip()) * 1000, 2)

    sched_sec = (scheduled_ts - created_ts).total_seconds() if scheduled_ts else 0.0
    container_init_sec = (started_ts - scheduled_ts).total_seconds() if (started_ts and scheduled_ts) else 0.0
    ready_wait_sec = (ready_ts - started_ts).total_seconds() if (ready_ts and started_ts) else 0.0
    total_ignition_sec = (ready_ts - created_ts).total_seconds() if ready_ts else 0.0

    print("\n" + "=" * 80)
    print(" SUMMARY BREAKDOWN: POD IGNITION LATENCY")
    print("=" * 80)
    print(f"Stage 1: Kube-Scheduler Placement       : {sched_sec:6.2f}s  ({(sched_sec/total_ignition_sec)*100 if total_ignition_sec else 0:4.1f}%)")
    print(f"Stage 2: Runtime Sandbox & Volume Mounts: {container_init_sec:6.2f}s  ({(container_init_sec/total_ignition_sec)*100 if total_ignition_sec else 0:4.1f}%)")
    print(f"Stage 3: Application Initialization (internal):")
    print(f"         - Python `import frappe`       : {app_timings['import_frappe_ms']:6.2f} ms")
    print(f"         - Frappe Site Config Load      : {app_timings['site_init_ms']:6.2f} ms")
    print(f"         - MariaDB TCP Connect & Auth   : {app_timings['db_connect_ms']:6.2f} ms")
    print(f"         - `frappe.ping` Handler Exec   : {app_timings['ping_exec_ms']:6.2f} ms")
    print(f"         - Total Cold Python Boot       : {app_timings['total_app_boot_ms']:6.2f} ms  (~{app_timings['total_app_boot_ms']/1000:4.2f}s)")
    print(f"Stage 4: Granian Local HTTP /ping Time  : {curl_time_ms:6.2f} ms")
    print(f"Stage 5: Readiness Probe Polling Interval: {ready_wait_sec:6.2f}s  ({(ready_wait_sec/total_ignition_sec)*100 if total_ignition_sec else 0:4.1f}%)")
    print("-" * 80)
    print(f"TOTAL TIME FROM POD CREATION TO READY   : {total_ignition_sec:6.2f}s")
    print("=" * 80)

if __name__ == "__main__":
    main()
