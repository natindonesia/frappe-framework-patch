# Frappe Framework Performance & RPS Profiling

Reproducible performance experiment to determine the exact **Requests Per Second (RPS) per CPU Core** and **CPU cost per request** for Frappe Framework on modern infrastructure.

---

## 1. Overview & Workload Types

This profiling suite isolates Frappe Framework operations into distinct, reproducible test workloads:

1. **Pure Read (`--workload read`):**
   - Querying list endpoints (`GET /api/resource/ToDo?limit=10`).
   - Tests WSGI/ASGI event loop, routing, authorization checking, and lightweight database query retrieval.
2. **Pure Write (`--workload write`):**
   - Transactional document insertion (`POST /api/resource/ToDo`).
   - Tests document validation (`validate()`), ORM lifecycle, permission checks, SQL insert transactions, and background queue enqueueing.
3. **Pure Update (`--workload update`):**
   - Document modification (`PUT /api/resource/ToDo/:id`).
   - Tests document fetching, dirty field checking, database updates, and version tracking.
4. **80% Read / 20% Write Mix (`--workload mix8020`):**
   - Authentic mixed production distribution: 80% list reads, 10% document inserts, 10% document updates.
5. **Full Lifecycle CRUD (`--workload crud`):**
   - Sequential document lifecycle: Create $\to$ Read $\to$ Update $\to$ List $\to$ Delete.

---

## 2. How to Run

### Options & Flags
```bash
./run_experiment.sh [OPTIONS]

Options:
  --workload <read|write|update|mix8020|crud>  Workload profile (default: read)
  --scenario <shock|burst|max>                 Preset load ramp profile
  --vus <number>                               Concurrent virtual users (default: 10)
  --duration <time>                            Benchmark duration e.g. 30s, 60s
  --site <hostname>                            Frappe site name (default: demo.fayolex.co.id)
  --mode <k8s|local>                           Run load generator inside cluster (default) or local
```
  --cleanup             Clean up benchmark user and leftover ToDos after test
  --help                Show usage information
```

### Examples

**Standard In-Cluster Run (10 concurrent users for 45s):**
```bash
./run_experiment.sh --mode k8s --vus 10 --duration 45s
```

**High Concurrency Test (25 concurrent users for 60s):**
```bash
./run_experiment.sh --mode k8s --vus 25 --duration 60s
```

**Run with Full Teardown / Cleanup:**
```bash
./run_experiment.sh --mode k8s --vus 5 --duration 30s --cleanup
```

---

## 4. Methodology & Metric Calculations

Continuous background monitoring (`monitor_cpu.py`) queries the raw Kubernetes metrics API (`/apis/metrics.k8s.io/v1beta1/namespaces/fayolex-working-staging/pods`) every 2 seconds before, during, and after the test to obtain nanosecond CPU readings.

### Metrics Computed:
- **RPS (Requests Per Second):**
  $$\text{RPS} = \frac{\text{Total Processed HTTP Requests}}{\text{Duration (seconds)}}$$

- **Delta CPU ($\Delta \text{mCPU}$):**
  $$\Delta \text{mCPU} = \text{Average Load mCPU} - \text{Idle Baseline mCPU}$$

- **Frappe Web RPS per Web CPU Core:**
  $$\text{RPS per Web Core} = \frac{\text{RPS}}{\Delta \text{CPU}_{\text{web}} / 1000}$$

- **Stack RPS per Total Stack Core:**
  $$\text{RPS per Total Stack Core} = \frac{\text{RPS}}{\Delta \text{CPU}_{\text{web + nginx + db + redis}} / 1000}$$

- **CPU Cost per Request:**
  $$\text{Cost per Request} = \frac{\Delta \text{CPU}_{\text{total}}}{\text{RPS}} \quad (\text{mCPU}\cdot\text{s per request})$$

---

## 5. Artifacts and Output Files

All experiment logs and JSON metrics are stored in `results/`:
- `results/report_<timestamp>.json`: Comprehensive analyzed metrics report.
- `results/cpu_samples_<timestamp>.json`: Time-series CPU and memory samples across all pods.
- `results/k6_summary_<timestamp>.json`: Standard k6 raw metrics export.
- `results/job_logs_<timestamp>.txt`: Full pod execution output.
