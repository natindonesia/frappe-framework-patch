#!/usr/bin/env python3
"""
monitor_cpu.py
Samples and analyzes CPU and Memory metrics for pods in Kubernetes namespaces.
Uses the raw Kubernetes Metrics API (metrics.k8s.io) for high-precision nanocore readings.
Calculates RPS, CPU cost per request, percentiles (p90, p95, p99), and error rates.
"""

import sys
import os
import json
import time
import signal
import subprocess
import argparse
from datetime import datetime

NAMESPACE = "default"
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
            # Classify component by label or prefix
            labels = item["metadata"].get("labels", {})
            comp = labels.get("app.kubernetes.io/name") or labels.get("app") or ""
            if not comp:
                for known in ["web", "nginx", "mariadb", "redis", "worker", "scheduler", "socketio", "otel-collector", "granian-adapter"]:
                    if known in pod_name:
                        comp = known
                        break
                if not comp:
                    comp = pod_name.split("-")[0]

            pod_cpu_nano = 0
            pod_mem_ki = 0
            for c in item.get("containers", []):
                cpu_raw = c.get("usage", {}).get("cpu", "0n")
                mem_raw = c.get("usage", {}).get("memory", "0Ki")

                nano = int(cpu_raw.rstrip("n")) if cpu_raw.endswith("n") else (
                    int(float(cpu_raw.rstrip("m")) * 1e6) if cpu_raw.endswith("m") else int(cpu_raw)
                )
                ki = int(mem_raw.rstrip("Ki")) if mem_raw.endswith("Ki") else (
                    int(float(mem_raw.rstrip("Mi")) * 1024) if mem_raw.endswith("Mi") else int(mem_raw)
                )

                pod_cpu_nano += nano
                pod_mem_ki += ki

            if comp not in metrics:
                metrics[comp] = {"cpu_nano": 0, "mem_ki": 0, "pods": 0}
            metrics[comp]["cpu_nano"] += pod_cpu_nano
            metrics[comp]["mem_ki"] += pod_mem_ki
            metrics[comp]["pods"] += 1

        return {
            "timestamp": time.time(),
            "iso_time": datetime.utcnow().isoformat() + "Z",
            "metrics": metrics
        }
    except Exception as e:
        return {}

def collect_loop(output_file, namespace=NAMESPACE, interval=2.0, duration=None, stop_trigger_file=None):
    """Collect metrics periodically until stopped or duration expires"""
    samples = []
    start_time = time.time()
    print(f"[*] Starting CPU sampling every {interval}s on namespace {namespace}...")

    try:
        while not STOP_FLAG:
            now = time.time()
            if duration and (now - start_time) > duration:
                break
            if stop_trigger_file and os.path.exists(stop_trigger_file):
                break

            m = query_pod_metrics(namespace=namespace)
            if m and "metrics" in m and m["metrics"]:
                samples.append(m)
                with open(output_file, "w") as f:
                    json.dump(samples, f, indent=2)

            time.sleep(interval)
    except KeyboardInterrupt:
        pass

    print(f"[*] Collected {len(samples)} samples. Saved to {output_file}.")
    return samples

def analyze_samples(samples, k6_summary_file=None):
    if len(samples) < 3:
        print("[!] Not enough samples collected for analysis.")
        return

    # Baseline is first 2 samples
    baseline_samples = samples[:2]
    # Under-load samples are everything from index 2 to end - 1
    load_samples = samples[2:-1] if len(samples) > 4 else samples[2:]

    def get_avg_cpu(sample_list):
        comp_totals = {}
        comp_counts = {}
        for s in sample_list:
            for comp, data in s["metrics"].items():
                mcpu = data["cpu_nano"] / 1e6
                comp_totals[comp] = comp_totals.get(comp, 0.0) + mcpu
                comp_counts[comp] = comp_counts.get(comp, 0) + 1
        return {k: comp_totals[k] / comp_counts[k] for k in comp_totals}

    def get_peak_cpu(sample_list):
        peaks = {}
        for s in sample_list:
            for comp, data in s["metrics"].items():
                mcpu = data["cpu_nano"] / 1e6
                if mcpu > peaks.get(comp, 0.0):
                    peaks[comp] = mcpu
        return peaks

    base_avg = get_avg_cpu(baseline_samples)
    load_avg = get_avg_cpu(load_samples)
    peak_cpu = get_peak_cpu(load_samples)

    summary = {}
    all_comps = set(base_avg.keys()) | set(load_avg.keys())
    for comp in all_comps:
        b = base_avg.get(comp, 0.0)
        l = load_avg.get(comp, 0.0)
        p = peak_cpu.get(comp, 0.0)
        delta = max(0.0, l - b)
        summary[comp] = {
            "baseline_mcpu": round(b, 2),
            "load_avg_mcpu": round(l, 2),
            "peak_mcpu": round(p, 2),
            "delta_mcpu": round(delta, 2)
        }

    # Total stack delta across core server components
    core_comps = ["web", "nginx", "mariadb", "redis", "socketio", "worker", "worker-default"]
    total_base = sum(summary[c]["baseline_mcpu"] for c in core_comps if c in summary)
    total_load = sum(summary[c]["load_avg_mcpu"] for c in core_comps if c in summary)
    total_peak = sum(summary[c]["peak_mcpu"] for c in core_comps if c in summary)
    total_delta = max(0.0, total_load - total_base)
    summary["__TOTAL_CORE_SERVERS__"] = {
        "baseline_mcpu": round(total_base, 2),
        "load_avg_mcpu": round(total_load, 2),
        "peak_mcpu": round(total_peak, 2),
        "delta_mcpu": round(total_delta, 2)
    }

    k6_data = {}
    if k6_summary_file and os.path.exists(k6_summary_file):
        try:
            with open(k6_summary_file) as f:
                k6_raw = json.load(f)
                req_metric = k6_raw.get("metrics", {}).get("http_reqs", {})
                dur_metric = k6_raw.get("metrics", {}).get("http_req_duration", {})
                failed_metric = k6_raw.get("metrics", {}).get("http_req_failed", {})
                
                rps = req_metric.get("rate", 0.0)
                total_reqs = req_metric.get("count", 0)
                avg_lat = dur_metric.get("avg", 0.0)
                p90_lat = dur_metric.get("p(90)", 0.0)
                p95_lat = dur_metric.get("p(95)", 0.0)
                p99_lat = dur_metric.get("p(99)", 0.0)
                
                err_rate = 0.0
                failed_reqs = 0
                if failed_metric:
                    err_rate = failed_metric.get("rate", failed_metric.get("value", 0.0))
                    failed_reqs = failed_metric.get("passes", 0)

                k6_data = {
                    "rps": round(rps, 2),
                    "total_requests": total_reqs,
                    "failed_requests": failed_reqs,
                    "error_rate_pct": round(err_rate * 100.0, 2),
                    "avg_latency_ms": round(avg_lat, 2),
                    "p90_latency_ms": round(p90_lat, 2),
                    "p95_latency_ms": round(p95_lat, 2),
                    "p99_latency_ms": round(p99_lat, 2),
                }
        except Exception as e:
            print(f"[!] Warning parsing k6 summary: {e}")

    # Compute key ratios
    efficiency = {}
    if k6_data.get("rps", 0) > 0:
        rps = k6_data["rps"]
        web_delta_cpu = summary.get("web", {}).get("delta_mcpu", 0.0)
        total_delta_cpu = summary.get("__TOTAL_CORE_SERVERS__", {}).get("delta_mcpu", 0.0)

        rps_per_web_core = (rps / (web_delta_cpu / 1000.0)) if web_delta_cpu > 0 else 0
        rps_per_stack_core = (rps / (total_delta_cpu / 1000.0)) if total_delta_cpu > 0 else 0
        mcpu_per_req = (total_delta_cpu / rps) if rps > 0 else 0

        efficiency = {
            "rps_per_web_core": round(rps_per_web_core, 2),
            "rps_per_stack_core": round(rps_per_stack_core, 2),
            "mcpu_per_req": round(mcpu_per_req, 2)
        }

    # Print clean formatted summary table
    print("\n" + "=" * 80)
    print(" EXPERIMENT RESULTS: FRAPPE BENCHMARK RPS & CPU METRICS")
    print("=" * 80)
    if k6_data:
        print(f" Workload Requests/sec (RPS) : {k6_data['rps']:.2f} req/s")
        print(f" Total HTTP Requests Processed : {k6_data['total_requests']}")
        print(f" Failed Requests (Error Rate) : {k6_data['failed_requests']} ({k6_data['error_rate_pct']}%)")
        print(f" Average Latency              : {k6_data['avg_latency_ms']:.2f} ms")
        print(f" 90th Percentile Latency (p90): {k6_data['p90_latency_ms']:.2f} ms")
        print(f" 95th Percentile Latency (p95): {k6_data['p95_latency_ms']:.2f} ms")
        print(f" 99th Percentile Latency (p99): {k6_data['p99_latency_ms']:.2f} ms")
        print("-" * 80)

    print(f"{'Component':<20} | {'Baseline (mCPU)':<16} | {'Load Avg (mCPU)':<16} | {'Peak (mCPU)':<14} | {'Delta (mCPU)':<12}")
    print("-" * 80)
    for comp in ["web", "nginx", "mariadb", "redis", "worker-default", "worker", "scheduler", "socketio", "otel-collector", "granian-adapter"]:
        if comp in summary:
            s = summary[comp]
            print(f"{comp:<20} | {s['baseline_mcpu']:<16.1f} | {s['load_avg_mcpu']:<16.1f} | {s['peak_mcpu']:<14.1f} | {s['delta_mcpu']:<12.1f}")

    if "__TOTAL_CORE_SERVERS__" in summary:
        s = summary["__TOTAL_CORE_SERVERS__"]
        print("-" * 80)
        print(f"{'TOTAL CORE SERVING':<20} | {s['baseline_mcpu']:<16.1f} | {s['load_avg_mcpu']:<16.1f} | {s['peak_mcpu']:<14.1f} | {s['delta_mcpu']:<12.1f}")
    print("=" * 80)

    if efficiency:
        print(" EFFICIENCY METRICS (RPS per CPU Usage):")
        print(f"  * Frappe Web RPS per Web CPU Core  : {efficiency['rps_per_web_core']:.2f} RPS / core")
        print(f"  * Stack RPS per Total CPU Core     : {efficiency['rps_per_stack_core']:.2f} RPS / core")
        print(f"  * CPU Cost per Request             : {efficiency['mcpu_per_req']:.2f} mCPU per RPS (mCPU*s / req)")
        print("=" * 80)

    return {
        "k6": k6_data,
        "cpu_summary": summary,
        "efficiency": efficiency
    }

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--namespace", default=NAMESPACE, help="Kubernetes namespace")
    parser.add_argument("--output", default="cpu-samples.json", help="Path to save samples")
    parser.add_argument("--interval", type=float, default=2.0, help="Sampling interval in seconds")
    parser.add_argument("--duration", type=float, default=None, help="Duration to sample")
    parser.add_argument("--k6-summary", default=None, help="Path to k6 summary JSON for correlation")
    parser.add_argument("--analyze-only", default=None, help="Analyze existing sample file without collecting")
    parser.add_argument("--report-json", default=None, help="Path to write final merged report JSON")
    parser.add_argument("--stop-trigger", default=None, help="Path to trigger file that stops collection immediately")
    args = parser.parse_args()

    if args.analyze_only:
        with open(args.analyze_only) as f:
            samples = json.load(f)
    elif os.path.exists(args.output) and not args.stop_trigger and not args.duration:
        with open(args.output) as f:
            samples = json.load(f)
    else:
        samples = collect_loop(args.output, namespace=args.namespace, interval=args.interval, duration=args.duration, stop_trigger_file=args.stop_trigger)

    result = analyze_samples(samples, args.k6_summary)
    if args.report_json and result:
        with open(args.report_json, "w") as f:
            json.dump(result, f, indent=2)
        print(f"\n[*] Final report JSON written to {args.report_json}")
