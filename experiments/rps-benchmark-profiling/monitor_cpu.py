#!/usr/bin/env python3
"""
monitor_cpu.py
Samples and analyzes CPU and Memory metrics for pods in fayolex-working-staging.
Uses the raw Kubernetes Metrics API (metrics.k8s.io) for high-precision nanocore readings.
"""

import sys
import os
import json
import time
import signal
import subprocess
import argparse
from datetime import datetime

NAMESPACE = "fayolex-working-staging"
STOP_FLAG = False

def handle_sig(sig, frame):
    global STOP_FLAG
    STOP_FLAG = True

signal.signal(signal.SIGINT, handle_sig)
signal.signal(signal.SIGTERM, handle_sig)

def query_pod_metrics(namespace=NAMESPACE):
    """Query metrics.k8s.io raw endpoint via kubectl"""
    try:
        out = subprocess.check_output(
            ["kubectl", "get", "--raw", f"/apis/metrics.k8s.io/v1beta1/namespaces/{namespace}/pods"],
            stderr=subprocess.DEVNULL,
            timeout=5
        )
        data = json.loads(out)
        metrics = {}
        for item in data.get("items", []):
            pod_name = item["metadata"]["name"]
            # Classify component by prefix/label
            comp = item["metadata"].get("labels", {}).get("app", "")
            if not comp:
                comp = pod_name.split("-")[0]

            pod_cpu_nano = 0
            pod_mem_ki = 0
            for c in item.get("containers", []):
                cpu_raw = c["usage"]["cpu"]
                mem_raw = c["usage"]["memory"]

                nano = int(cpu_raw.rstrip("n")) if cpu_raw.endswith("n") else (
                    int(float(cpu_raw.rstrip("m")) * 1e6) if cpu_raw.endswith("m") else int(cpu_raw)
                )
                ki = int(mem_raw.rstrip("Ki")) if mem_raw.endswith("Ki") else (
                    int(float(mem_raw.rstrip("Mi")) * 1024) if mem_raw.endswith("Mi") else int(mem_raw)
                )
                pod_cpu_nano += nano
                pod_mem_ki += ki

            mcpu = pod_cpu_nano / 1e6
            mem_mb = pod_mem_ki / 1024
            metrics[pod_name] = {
                "component": comp,
                "cpu_mcpu": round(mcpu, 2),
                "mem_mb": round(mem_mb, 2)
            }
        return metrics
    except Exception as e:
        return {}

def collect_loop(output_file, interval=2.0, duration=None, stop_trigger_file=None):
    """Collect metrics periodically until stopped or duration expires"""
    samples = []
    start_time = time.time()
    print(f"[*] Starting CPU sampling every {interval}s on namespace {NAMESPACE}...")

    try:
        while not STOP_FLAG:
            now = time.time()
            if duration and (now - start_time) >= duration:
                break
            if stop_trigger_file and os.path.exists(stop_trigger_file):
                break

            m = query_pod_metrics()
            if m:
                samples.append({
                    "timestamp": round(now, 2),
                    "relative_sec": round(now - start_time, 2),
                    "pods": m
                })
            time.sleep(interval)
    except KeyboardInterrupt:
        pass

    with open(output_file, "w") as f:
        json.dump(samples, f, indent=2)
    print(f"[*] Collected {len(samples)} samples. Saved to {output_file}")
    return samples

def analyze_samples(samples, k6_summary_file=None):
    """Compute baseline, peak, average, and RPS per CPU metrics"""
    if not samples:
        print("[!] No samples collected.")
        return

    # Aggregate by component
    component_samples = {}
    for sample in samples:
        for pod_name, data in sample["pods"].items():
            comp = data["component"]
            if comp not in component_samples:
                component_samples[comp] = []
            component_samples[comp].append(data["cpu_mcpu"])

    # Split into baseline (first 15%) vs active load (middle 70%) if long run
    n = len(samples)
    baseline_split = max(1, int(n * 0.2)) if n > 10 else 1

    summary = {}
    total_baseline_m = 0.0
    total_load_m = 0.0
    total_peak_m = 0.0

    for comp, c_samples in component_samples.items():
        if not c_samples:
            continue
        base_val = sum(c_samples[:baseline_split]) / baseline_split
        # load val over all samples or active period
        active_samples = c_samples[baseline_split:] if len(c_samples) > baseline_split else c_samples
        load_avg = sum(active_samples) / len(active_samples)
        peak_val = max(c_samples)
        delta_m = max(0.0, load_avg - base_val)

        summary[comp] = {
            "baseline_mcpu": round(base_val, 2),
            "load_avg_mcpu": round(load_avg, 2),
            "peak_mcpu": round(peak_val, 2),
            "delta_mcpu": round(delta_m, 2)
        }

        # Focus on core serving components
        if comp in ["web", "nginx", "mariadb", "redis"]:
            total_baseline_m += base_val
            total_load_m += load_avg
            total_peak_m += peak_val

    total_delta_m = max(0.0, total_load_m - total_baseline_m)
    summary["__TOTAL_CORE_SERVERS__"] = {
        "baseline_mcpu": round(total_baseline_m, 2),
        "load_avg_mcpu": round(total_load_m, 2),
        "peak_mcpu": round(total_peak_m, 2),
        "delta_mcpu": round(total_delta_m, 2)
    }

    # If k6 summary is present, calculate RPS / CPU ratios
    k6_data = {}
    rps = 0.0
    total_reqs = 0
    p95_lat = 0.0
    p90_lat = 0.0
    avg_lat = 0.0

    if k6_summary_file and os.path.exists(k6_summary_file):
        try:
            with open(k6_summary_file) as kf:
                raw_k6 = json.load(kf)
                metrics = raw_k6.get("metrics", {})
                reqs_metric = metrics.get("http_reqs", {})
                if "values" in reqs_metric and isinstance(reqs_metric["values"], dict):
                    rps = reqs_metric["values"].get("rate", 0.0)
                    total_reqs = reqs_metric["values"].get("count", 0)
                else:
                    rps = reqs_metric.get("rate", 0.0)
                    total_reqs = reqs_metric.get("count", 0)

                dur_metric = metrics.get("http_req_duration", {})
                if "values" in dur_metric and isinstance(dur_metric["values"], dict):
                    dur_vals = dur_metric["values"]
                else:
                    dur_vals = dur_metric
                p95_lat = dur_vals.get("p(95)", 0.0)
                p90_lat = dur_vals.get("p(90)", 0.0)
                avg_lat = dur_vals.get("avg", 0.0)

                k6_data = {
                    "rps": round(rps, 2),
                    "total_requests": total_reqs,
                    "avg_latency_ms": round(avg_lat, 2),
                    "p90_latency_ms": round(p90_lat, 2),
                    "p95_latency_ms": round(p95_lat, 2),
                }
        except Exception as e:
            print(f"[!] Warning parsing k6 summary: {e}")

    # Print ASCII Report
    print("\n" + "=" * 80)
    print(f" EXPERIMENT RESULTS: {NAMESPACE} RPS & CPU METRICS")
    print("=" * 80)

    if k6_data:
        print(f" Workload Requests/sec (RPS) : {k6_data['rps']:.2f} req/s")
        print(f" Total HTTP Requests Processed : {k6_data['total_requests']}")
        print(f" Average Latency              : {k6_data['avg_latency_ms']:.2f} ms")
        print(f" 90th Percentile Latency (p90): {k6_data['p90_latency_ms']:.2f} ms")
        print(f" 95th Percentile Latency (p95): {k6_data['p95_latency_ms']:.2f} ms")
        print("-" * 80)

    print(f"{'Component':<20} | {'Baseline (mCPU)':<16} | {'Load Avg (mCPU)':<16} | {'Peak (mCPU)':<14} | {'Delta (mCPU)':<12}")
    print("-" * 80)
    for comp in ["web", "nginx", "mariadb", "redis", "worker", "socketio", "otel-collector"]:
        if comp in summary:
            s = summary[comp]
            print(f"{comp:<20} | {s['baseline_mcpu']:<16.1f} | {s['load_avg_mcpu']:<16.1f} | {s['peak_mcpu']:<14.1f} | {s['delta_mcpu']:<12.1f}")

    tot = summary["__TOTAL_CORE_SERVERS__"]
    print("-" * 80)
    print(f"{'TOTAL CORE SERVING':<20} | {tot['baseline_mcpu']:<16.1f} | {tot['load_avg_mcpu']:<16.1f} | {tot['peak_mcpu']:<14.1f} | {tot['delta_mcpu']:<12.1f}")
    print("=" * 80)

    if rps > 0:
        web_delta_cores = (summary.get("web", {}).get("delta_mcpu", 0.0)) / 1000.0
        tot_delta_cores = tot["delta_mcpu"] / 1000.0

        web_rps_per_core = (rps / web_delta_cores) if web_delta_cores > 0.001 else 0.0
        tot_rps_per_core = (rps / tot_delta_cores) if tot_delta_cores > 0.001 else 0.0
        mcpu_per_req = (tot["delta_mcpu"] / rps) if rps > 0 else 0.0

        print(" EFFICIENCY METRICS (RPS per CPU Usage):")
        print(f"  * Frappe Web RPS per Web CPU Core  : {web_rps_per_core:.2f} RPS / core")
        print(f"  * Stack RPS per Total CPU Core     : {tot_rps_per_core:.2f} RPS / core")
        print(f"  * CPU Cost per Request             : {mcpu_per_req:.2f} mCPU per RPS (mCPU*s / req)")
        print("=" * 80 + "\n")

    return {
        "k6": k6_data,
        "cpu_summary": summary,
        "efficiency": {
            "rps_per_web_core": round(web_rps_per_core, 2) if rps > 0 and web_delta_cores > 0.001 else None,
            "rps_per_stack_core": round(tot_rps_per_core, 2) if rps > 0 and tot_delta_cores > 0.001 else None,
            "mcpu_per_req": round(mcpu_per_req, 2) if rps > 0 else None
        } if rps > 0 else {}
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", default="cpu-samples.json", help="Path to save samples")
    parser.add_argument("--interval", type=float, default=2.0, help="Sampling interval in seconds")
    parser.add_argument("--duration", type=float, default=None, help="Duration to sample")
    parser.add_argument("--stop-trigger", default=None, help="Stop sampling when this file exists")
    parser.add_argument("--analyze-only", action="store_true", help="Only analyze existing output file")
    parser.add_argument("--k6-summary", default=None, help="Path to k6 summary JSON")
    parser.add_argument("--report-json", default=None, help="Save final analyzed report to JSON")
    args = parser.parse_args()

    if args.analyze_only:
        with open(args.output) as f:
            samples = json.load(f)
    else:
        samples = collect_loop(args.output, interval=args.interval, duration=args.duration, stop_trigger_file=args.stop_trigger)

    result = analyze_samples(samples, args.k6_summary)
    if args.report_json and result:
        with open(args.report_json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"[*] Final report JSON written to {args.report_json}")
