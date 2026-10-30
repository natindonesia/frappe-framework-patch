# WSGI Wall-Time Profiling & OpenTelemetry Correlation

Frappe's WSGI runtime in this image includes a built-in deterministic wall-clock profiler with OpenTelemetry (OTel) trace correlation, percentiles distribution analysis, and multi-worker aggregation.

Unlike default CPU profilers on Linux, the wall-clock profiler uses Python's `time.perf_counter` timer to record **true elapsed execution time**, accurately capturing:
- MariaDB / SQL query latency (`db.sql`, `cursor.execute`)
- Redis cache operations
- External network/HTTP calls (`requests`)
- Template rendering and disk/JuiceFS read/write waits
- Frappe ORM lifecycle hooks (`validate`, `on_update`, permission checks)

---

## 1. Quick Start

### Enable in Kubernetes / GitOps (`values.yaml`)

Under your web deployment configuration (e.g. `multicloud/gcore/gitops/my-nds-development/values.yaml`):

```yaml
web:
  env:
    - name: ENABLE_WALL_PROFILING
      value: "1"
```

### Enable in Docker Compose (`docker-compose.yml` or `.env`)

```yaml
services:
  web:
    environment:
      - ENABLE_WALL_PROFILING=1
      - WALL_PROFILING_DIR=/home/frappe/frappe-bench/sites/profiles
```

### Enable in Local Development / Bench

```bash
export SITES_PATH="/path/to/frappe-bench/sites"
export ENABLE_WALL_PROFILING="1"
export WALL_PROFILING_DIR="/tmp/profiles"

# Start web worker
granian --interface wsgi --host 0.0.0.0 --port 8000 frappe.otel_wsgi:application
```

---

## 2. Environment Variables Reference

| Variable | Default | Description |
|---|---|---|
| `ENABLE_WALL_PROFILING` | `0` (off) | Set to `1`, `true`, or `yes` to activate the profiler middleware. |
| `WALL_PROFILING_DIR` | `<SITES_PATH>/profiles` | Target directory for individual `.prof` files. |
| `WALL_PROFILING_IGNORE` | `/api/method/ping,/healthz,/assets,/favicon.ico` | Comma-separated URL path prefixes to bypass without generating profiles. |

---

## 3. Profile File Structure & OTel Trace Correlation

When active, each request writes a binary `.prof` file into `WALL_PROFILING_DIR`.

### Automatic Trace Correlation

If OpenTelemetry is active (`OTEL_EXPORTER_OTLP_ENDPOINT` is configured):

1. **File to Trace**: The W3C Trace ID is embedded in the profile filename:
   ```text
   req_<timestamp>_<pid>_trace_<trace_id>_<clean_path>.prof
   ```
   *Example:* `req_1793271222981_932161_trace_40e61347120dd27d3a2a26f6319e8938_api_resource_ToDo.prof`

2. **Trace to File**: The root WSGI span in OpenTelemetry is annotated with the profile's metadata:
   - `frappe.profile.file`: Absolute path to the `.prof` file on disk.
   - `frappe.profile.wall_time_ms`: Total elapsed wall-clock latency.
   - `frappe.profile.total_calls`: Total Python function calls executed.

When viewing an outlier trace in **Grafana Tempo** or **Jaeger**, copy the `trace_id` or look at `frappe.profile.file` to inspect the exact profile on disk.

---

## 4. Analyzing Percentile Latency Distributions

To calculate latency percentiles (p50, p90, p95, p99), averages, and an endpoint breakdown across all captured profiles:

```bash
python -m frappe.otel_wsgi --distribution [PROFILE_DIR]
```

### In Kubernetes:

```bash
kubectl exec -it -n my-nds-development deployment/web -c web -- \
  /home/frappe/frappe-bench/env/bin/python3 -m frappe.otel_wsgi --distribution
```

### Output Format:

```text
================================================================================
REQUEST WALL-TIME LATENCY DISTRIBUTION
================================================================================
Sample Size : 1,240 requests
Mean        :   142.15 ms  (± 38.40 ms)
Min         :    18.20 ms
p50 (Median):    94.50 ms
p90         :   285.10 ms
p95         :   412.30 ms
p99         :   790.80 ms
Max         :  1,420.50 ms

--------------------------------------------------------------------------------
BREAKDOWN BY ENDPOINT
--------------------------------------------------------------------------------
Endpoint                   Count   p50 (ms)   p90 (ms)   p95 (ms)   Max (ms)
--------------------------------------------------------------------------------
api_resource_ToDo            820      88.20     210.40     340.10     890.20
login                        310     110.50     320.10     480.20   1,420.50

--------------------------------------------------------------------------------
TOP OUTLIER (SLOWEST) REQUESTS FOR TRACE CORRELATION
--------------------------------------------------------------------------------
 1420.50 ms | login | OTel Trace ID: 40e61347120dd27d3a2a26f6319e8938 | req_..._login.prof
```

---

## 5. Aggregating Profiles

Consolidate thousands of individual request profiles across all pods/workers into a single cumulative profile:

```bash
python -m frappe.otel_wsgi --aggregate [PROFILE_DIR] [OUTPUT_FILE]
```

By default, this writes `aggregated.prof` inside the profile directory and prints the top 30 functions sorted by cumulative wall time.

---

## 6. Interactive Visualizations

### Visualizing with SnakeViz (Web Browser)

```bash
pip install snakeviz
snakeviz /path/to/aggregated.prof
```
- Toggle between **Sunburst** and **Icicle** view modes.
- Click any function block to zoom in and expand its call stack.

### Visualizing with Flamegraph SVG

```bash
pip install flameprof
python -m flameprof -o flamegraph.svg /path/to/aggregated.prof
```
Open `flamegraph.svg` in any web browser for an interactive, zoomable SVG.
