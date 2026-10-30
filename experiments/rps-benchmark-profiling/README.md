# Frappe Framework Performance & RPS Profiling

Reproducible performance suite to determine the exact **Requests Per Second (RPS) per CPU Core**, **CPU cost per request**, and **concurrency shock tolerance** for Frappe Framework on cloud-native Kubernetes infrastructure.

> [!NOTE]
> **Public Reading Note: Interpreting These Results**
> - **Workload Authenticity (Login + CRUD):** The 235 RPS reported below is **NOT** a synthetic `ping` or static read cache hit. It is the aggregate throughput of an authentic **Interactive Login + Full Transactional CRUD** lifecycle:
>   - **50.0% Database Writes** (`POST` ToDo + `PUT` ToDo + `DELETE` ToDo): 117.5 writes/sec
>   - **33.3% Database Reads** (`GET` ToDo by ID + `GET` ToDo list query): 78.3 reads/sec
>   - **16.7% Interactive Logins** (`POST /api/method/login`): 39.2 logins/sec
>   - **Completed User Journeys:** Exactly **39.17 complete 6-step lifecycles per second** with **0.00% error rate**.
> - **Storage Hardware Reality (SATA SSD RAID-1, NOT NVMe):** The database storage runs on commodity **2x 500 GB SATA SSDs (Samsung SSD 870, SATA 6Gbps) in Software RAID-1**, **NOT** PCIe NVMe. Despite commodity SATA storage, MariaDB maintained a **99.96% InnoDB buffer pool hit ratio** and consumed only **1.4 cores peak**, confirming that storage I/O and MariaDB are not the throttle. The bottleneck lies squarely in WSGI worker process concurrency (Python GIL).
> - **Reproducibility:** All k6 workloads, CPU instrumentation scripts, and manifests in this repository are generic, self-contained, and parameterizable via CLI flags.

---

## 1. Workload Profiles

The profiling suite isolates Frappe operations into distinct, reproducible test workloads:

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
   - Sequential document lifecycle: Login $\to$ Create $\to$ Read $\to$ Update $\to$ List $\to$ Delete.

---

## 2. How to Run

### Command-Line Options
```bash
./run_experiment.sh [OPTIONS]

Options:
  --namespace <ns>      Target Kubernetes namespace (default: frappe-bench)
  --site <hostname>     Frappe site hostname (default: frappe.local)
  --target-url <url>    Target HTTP/HTTPS URL (default: https://<site>)
  --mode <k8s|local>    Run load generator inside k8s (default) or locally
  --workload <type>     Workload: 'read', 'write', 'update', 'mix8020', or 'crud' (default: crud)
  --scenario <name>     Preset scenario: 'shock' (instant surge), 'burst', or 'max'
  --vus <number>        Number of concurrent virtual users (default: 10)
  --duration <time>     Test duration, e.g. 30s, 60s, 2m (default: 45s)
  --login <true|false>  Include session authentication in each cycle (default: true)
  --cold <true|false>   Scale web deployment to 1 cold replica before test (default: true)
  --cleanup             Clean up benchmark users and test records after run
  --help                Show usage information
```

### Examples

**Instant Concurrency Shock Test (50 VUs, instant rush, starting with 1 cold pod):**
```bash
./run_experiment.sh --namespace frappe-bench --site frappe.local --scenario shock --vus 50 --duration 30s
```

**Standard In-Cluster CRUD Test (20 concurrent users for 45s):**
```bash
./run_experiment.sh --namespace frappe-bench --site frappe.local --vus 20 --duration 45s
```

**Local Testing with Host Network:**
```bash
./run_experiment.sh --mode local --site frappe.local --target-url http://localhost:8000 --vus 10 --duration 30s
```

---

## 3. Shock Test Findings Summary (1 Cold Web Pod)

Benchmark progression tested against a single cold web pod with instant concurrency and zero warm-up.

> [!IMPORTANT]
> **What does 235 RPS represent?**
> The 235 RPS throughput is **NOT** a synthetic `ping` or read cache hit. It is the aggregate throughput of an authentic **Interactive Login + Full Transactional CRUD** lifecycle. Every iteration executes 6 sequential HTTP calls:
> - **16.7% Session Login** (`POST /api/method/login`): 39.2 logins/sec
> - **50.0% Database Writes** (`POST` ToDo + `PUT` ToDo + `DELETE` ToDo): 117.5 writes/sec
> - **33.3% Database Reads** (`GET` ToDo by ID + `GET` ToDo list query): 78.3 reads/sec
> 
> At peak (235.00 RPS), the single pod processed **11,904 total HTTP requests** and completed **39.17 full 6-step user lifecycles per second** with **0.00% errors**.

| Concurrency (VUs) | Throughput (RPS) | Requests Processed | Error Rate (%) | Avg Latency (ms) | p90 (ms) | p95 (ms) | p99 (ms) | Web Peak CPU (cores) | MariaDB Peak CPU (cores) |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **20 VUs** | **208.85** | 10,518 | **0.00%** | **95.24** | 226.35 | 284.43 | **385.86** | 4.03 | 1.18 |
| **35 VUs** | **232.29** | 11,712 | **0.00%** | **149.94** | 331.83 | 402.60 | **545.09** | 4.43 | 1.27 |
| **50 VUs** | **235.00** | 11,904 | **0.00%** | **211.62** | 438.51 | 511.44 | **676.78** | 4.67 | 1.42 |
| **65 VUs** | **234.70** | 11,916 | **0.00%** | **274.56** | 604.78 | 707.68 | **905.99** | 4.72 | 1.35 |
| **80 VUs** | **223.99** | 11,442 | **0.00%** | **353.80** | 776.54 | 917.99 | **1,208.18** | 4.70 | 1.26 |
| **100 VUs** | **225.10** | 11,472 | **0.00%** | **440.48** | 860.11 | 1,001.16 | **1,323.71** | 4.52 | 1.40 |
| **120 VUs** | **230.75** | 11,826 | **0.00%** | **514.27** | 1,011.70 | 1,137.06 | **1,391.49** | 4.34 | 1.44 |

- **Highest Clean RPS:** **235.00 RPS** at 50 VUs.
- **Error Rate:** **0.00% clean pass** across all concurrency levels.
- **Sub-Second p99 Envelope:** Sustained up to **65 concurrent VUs** ($p_{99} = 905.99\text{ ms}$).

---

## 4. Hardware Specifications & MariaDB Tuning

To enable apples-to-apples comparison across different environments and platforms:

### Bare Metal Host Specifications
- **CPU:** AMD Ryzen 9 5950X (16 Cores, 32 Threads, 3.4 GHz base / up to 4.90 GHz boost, 64MB L3 Cache).
- **RAM:** 128 GB DDR4 ECC RAM (3200 MHz).
- **Storage Subsystem:** 2x 500 GB SATA SSDs (Samsung SSD 870, SATA 6Gbps) in Software RAID-1, mounted via local storage provisioner (**NOT** NVMe).
- **Network / OS:** 1 Gbps / 10 Gbps Uplink, Ubuntu 24.04 LTS, Cilium CNI.
- **Container Runtime:** CRI-O on Kubernetes v1.36.x.

### Active MariaDB Database Tuning (`my.cnf`)
```ini
[mysqld]
innodb_buffer_pool_size = 1G
innodb_log_file_size = 256M
innodb_flush_method = O_DIRECT
innodb_io_capacity = 200
max_connections = 200
max_allowed_packet = 256M
binlog_format = ROW
gtid_strict_mode = OFF
sync_binlog = 1
skip_name_resolve
```

See [`FINDINGS.md`](./FINDINGS.md) for full architectural analysis and bottleneck breakdown.

---

## 5. Methodology & Metric Calculations

Continuous background monitoring (`monitor_cpu.py`) queries the raw Kubernetes metrics API (`/apis/metrics.k8s.io/v1beta1/namespaces/<ns>/pods`) every 2 seconds before, during, and after the test to obtain nanosecond CPU readings.

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
