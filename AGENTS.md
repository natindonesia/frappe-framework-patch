# Repository Agent Rules

## Information Disclosure & Sanitization

### 1. Strictly Prohibited: Organization-Specific Information
Never disclose or commit organization-specific identifiers or infrastructure metadata, including:
- **Cloud & Hosting Providers:** Do not mention hosting providers, cloud vendor account identifiers, or proprietary managed cloud services.
- **Internal Domain Names & URLs:** Do not disclose internal domain names, private subdomains (e.g., `*.natracker.com`), or internal endpoint paths. Use generic placeholders like `frappe.local` or `https://<site>`.
- **Internal Cluster & Node Identifiers:** Do not expose internal Kubernetes namespaces, internal cluster/deployment names, node pool IDs, machine deployment hashes, or private IP/CIDR ranges.
- **Internal Device Nodes & Paths:** Do not include local host-specific device paths (e.g., `/dev/md126` or internal disk partition serials).
- **Credentials & Identity:** Never include internal user accounts, passwords, API tokens, internal emails, or secret keys.

### 2. Permitted & Encouraged: Technical & Hardware Specifications
For benchmark accuracy, profiling reproducibility, and architectural clarity, concrete technical details are fully permitted:
- **Bare-Metal Hardware Specifications:** CPU model (e.g., AMD Ryzen 9 5950X, core/thread counts, clock boost frequencies, cache hierarchy), system RAM (capacity, DDR generation, ECC, frequency), and storage subsystem type (e.g., SATA 6Gbps SSD, NVMe, Software RAID-1).
- **Operating System & Runtime:** General OS family and version (e.g., Ubuntu 24.04 LTS, Linux 6.8 x86_64), container runtimes (e.g., CRI-O), Kubernetes version (e.g., v1.36.x), and CNI (e.g., Cilium).
- **Service & Database Configuration:** Generic database parameters (e.g., `innodb_buffer_pool_size`, `innodb_flush_method`, `max_connections`), web server tuning (e.g., Granian worker/thread counts, socket backlog), and container resource requests/limits.
