#!/usr/bin/env bash
#
# run_experiment.sh
# Automated, reproducible RPS per CPU benchmark for Frappe Framework on Kubernetes.
#
# Usage:
#   ./run_experiment.sh [--namespace <ns>] [--site <hostname>] [--target-url <url>]
#                       [--mode k8s|local] [--vus 10] [--duration 45s] [--scenario shock]
#                       [--workload crud] [--login true|false] [--cleanup]
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

NAMESPACE="${NAMESPACE:-frappe-bench}"
MODE="k8s"
VUS="10"
DURATION="45s"
SITE="${SITE:-frappe.local}"
TARGET_URL=""
ENABLE_LOGIN="true"
DO_CLEANUP="false"
STEPPED="false"
SCENARIO=""
WORKLOAD_TYPE="crud"
COLD_START="true"
BENCH_USER="bench_loadtest_user@example.com"
BENCH_PASS="BenchPassword123!"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"; shift 2 ;;
    --mode)
      MODE="$2"; shift 2 ;;
    --vus)
      VUS="$2"; shift 2 ;;
    --duration)
      DURATION="$2"; shift 2 ;;
    --scenario)
      SCENARIO="$2"; shift 2 ;;
    --workload)
      WORKLOAD_TYPE="$2"; shift 2 ;;
    --site)
      SITE="$2"; shift 2 ;;
    --target-url)
      TARGET_URL="$2"; shift 2 ;;
    --login)
      ENABLE_LOGIN="$2"; shift 2 ;;
    --cold)
      COLD_START="$2"; shift 2 ;;
    --cleanup)
      DO_CLEANUP="true"; shift 1 ;;
    --stepped)
      STEPPED="true"; shift 1 ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "  --namespace <ns>      Target namespace (default: frappe-bench)"
      echo "  --site <hostname>     Frappe site name (default: frappe.local)"
      echo "  --target-url <url>    Target HTTP/HTTPS URL (default: https://<site>)"
      echo "  --mode <k8s|local>    Run load generator in k8s (default) or locally"
      echo "  --vus <number>        Number of concurrent virtual users (default: 10)"
      echo "  --duration <time>     Benchmark duration e.g. 30s, 60s (default: 45s)"
      echo "  --scenario <name>     Preset scenario: 'shock' (instant rush), 'burst', or 'max'"
      echo "  --workload <type>     Workload: 'read', 'write', 'update', 'mix8020', or 'crud'"
      echo "  --login <true|false>  Include session login in workload (default: true)"
      echo "  --cold <true|false>   Scale web deployment to 1 cold replica before test (default: true)"
      echo "  --cleanup             Clean up dummy user and benchmark todos after run"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

TARGET_URL="${TARGET_URL:-https://${SITE}}"

echo "================================================================================"
echo " Starting Benchmark Experiment for namespace: ${NAMESPACE}"
echo " Target URL: ${TARGET_URL} | Site: ${SITE} | Mode: ${MODE}"
echo " Scenario: ${SCENARIO:-custom} | Workload: ${WORKLOAD_TYPE} | VUs: ${VUS} | Duration: ${DURATION}"
echo "================================================================================"

# Verify kubectl access
if ! kubectl get ns "${NAMESPACE}" >/dev/null 2>&1; then
  echo "[!] Error: cannot access namespace ${NAMESPACE} via kubectl"
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_ID="${NAMESPACE}-bench-${TIMESTAMP}"
STOP_TRIGGER="/tmp/bench_stop_${TIMESTAMP}"
CPU_SAMPLES_FILE="${RESULTS_DIR}/cpu_samples_${TIMESTAMP}.json"
K6_SUMMARY_FILE="${RESULTS_DIR}/k6_summary_${TIMESTAMP}.json"
REPORT_JSON_FILE="${RESULTS_DIR}/report_${TIMESTAMP}.json"

# Step 1: Instate dummy user pool and API keys in Frappe pod
echo "[1/5] Instate dummy users and API keys in Frappe pod..."
# Target web or worker deployment
BENCH_POD=$(kubectl get pods -n "${NAMESPACE}" -l app.kubernetes.io/name=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "${BENCH_POD}" ]; then
  BENCH_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=web -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi
if [ -z "${BENCH_POD}" ]; then
  BENCH_POD=$(kubectl get pods -n "${NAMESPACE}" -l app=worker-default -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
fi

if [ -z "${BENCH_POD}" ]; then
  echo "[!] Could not locate a web or worker pod in namespace ${NAMESPACE}"
  exit 1
fi

USER_SETUP_OUT=$(kubectl exec -i -n "${NAMESPACE}" "${BENCH_POD}" -- \
  env BENCH_SITE="${SITE}" \
      BENCH_NUM_USERS="120" \
      BENCH_ACTION="create" \
  /home/frappe/frappe-bench/env/bin/python3 - < "${SCRIPT_DIR}/setup_bench_user.py")

USERS_JSON_FILE="${RESULTS_DIR}/users_${TIMESTAMP}.json"
echo "${USER_SETUP_OUT}" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    users = data.get('users', [])
    with open('${USERS_JSON_FILE}', 'w') as f:
        json.dump(users, f, indent=2)
    print(f'      [+] Configured pool of {len(users)} test users with API keys.')
except Exception as e:
    print('[!] Error parsing user setup output:', e, file=sys.stderr)
"

API_KEY=$(python3 -c "import json; u=json.load(open('${USERS_JSON_FILE}')); print(u[0]['api_key'] if u else '')")
API_SECRET=$(python3 -c "import json; u=json.load(open('${USERS_JSON_FILE}')); print(u[0]['api_secret'] if u else '')")
BENCH_USER=$(python3 -c "import json; u=json.load(open('${USERS_JSON_FILE}')); print(u[0]['email'] if u else '')")
BENCH_PASS=$(python3 -c "import json; u=json.load(open('${USERS_JSON_FILE}')); print(u[0]['password'] if u else '')")

if [ -z "${API_KEY}" ] || [ -z "${API_SECRET}" ]; then
  echo "[!] Failed to retrieve API Key and API Secret from bench container!"
  echo "Output was: ${USER_SETUP_OUT}"
  exit 1
fi
echo "      Primary User: ${BENCH_USER}"
echo "      Primary API Key: ${API_KEY}"

# Optional cold start enforcement
if [ "${COLD_START}" = "true" ]; then
  echo "      Ensuring web deployment starts from 1 replica (cold start)..."
  kubectl scale deployment web --replicas=1 -n "${NAMESPACE}" >/dev/null 2>&1 || true
  kubectl wait --for=condition=Ready pod -l app=web -n "${NAMESPACE}" --timeout=60s >/dev/null 2>&1 || true
  echo "      web deployment verified at 1 replica."
fi

# Step 2: Start background CPU sampler to record baseline & under-load metrics
echo "[2/5] Starting pod CPU monitoring on namespace ${NAMESPACE}..."
rm -f "${STOP_TRIGGER}"
python3 "${SCRIPT_DIR}/monitor_cpu.py" \
  --namespace "${NAMESPACE}" \
  --output "${CPU_SAMPLES_FILE}" \
  --stop-trigger "${STOP_TRIGGER}" \
  --interval 2.0 > /dev/null 2>&1 &
MONITOR_PID=$!

echo "      Waiting 6s to establish idle baseline..."
sleep 6

# Step 3: Run the workload
echo "[3/5] Executing benchmark workload (Mode: ${MODE} | Scenario: ${SCENARIO:-custom} | Workload: ${WORKLOAD_TYPE})..."

if [ "${MODE}" = "k8s" ]; then
  JOB_NAME="frappe-benchmark-job"
  CM_NAME="frappe-benchmark-config"

  # Clean up any leftover job or configmap
  kubectl delete job "${JOB_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete configmap "${CM_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true

  # Create ConfigMap with test script and user pool
  kubectl create configmap "${CM_NAME}" -n default \
    --from-file="k6-workload.js=${SCRIPT_DIR}/k6-workload.js" \
    --from-file="users.json=${USERS_JSON_FILE}" \
    --dry-run=client -o yaml | kubectl apply -n default -f - >/dev/null

  # Render Job manifest
  JOB_YAML="${RESULTS_DIR}/job_${TIMESTAMP}.yaml"
  cat "${SCRIPT_DIR}/k8s-job.yaml.template" | \
    sed "s|\${TARGET_URL}|${TARGET_URL}|g" | \
    sed "s|\${API_KEY}|${API_KEY}|g" | \
    sed "s|\${API_SECRET}|${API_SECRET}|g" | \
    sed "s|\${USER_EMAIL}|${BENCH_USER}|g" | \
    sed "s|\${USER_PASSWORD}|${BENCH_PASS}|g" | \
    sed "s|\${ENABLE_LOGIN}|${ENABLE_LOGIN}|g" | \
    sed "s|\${WORKLOAD_TYPE}|${WORKLOAD_TYPE}|g" | \
    sed "s|\${SCENARIO}|${SCENARIO}|g" | \
    sed "s|\${TEST_VUS}|${VUS}|g" | \
    sed "s|\${TEST_DURATION}|${DURATION}|g" > "${JOB_YAML}"

  kubectl apply -f "${JOB_YAML}" >/dev/null
  echo "      Job applied. Waiting for pod to start..."

  # Wait for pod to run
  for i in $(seq 1 30); do
    POD_NAME=$(kubectl get pods -n default -l app.kubernetes.io/name=frappe-benchmark -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "${POD_NAME}" ]; then
      POD_STATUS=$(kubectl get pod "${POD_NAME}" -n default -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "${POD_STATUS}" = "Running" ] || [ "${POD_STATUS}" = "Succeeded" ]; then
        break
      fi
    fi
    sleep 1
  done

  echo "      Pod ${POD_NAME} running. Streaming execution logs:"
  JOB_LOGS="${RESULTS_DIR}/job_logs_${TIMESTAMP}.txt"
  kubectl logs -f "${POD_NAME}" -n default -c k6-runner 2>&1 | tee "${JOB_LOGS}"

  # Extract K6 summary JSON from logs
  python3 -c "
import sys, re
with open('${JOB_LOGS}') as f:
    text = f.read()
m = re.search(r'===K6_SUMMARY_START===\s*(\{.*?\})\s*===K6_SUMMARY_END===', text, re.DOTALL)
if m:
    with open('${K6_SUMMARY_FILE}', 'w') as out:
        out.write(m.group(1))
"

  # Clean up job and configmap
  kubectl delete job "${JOB_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete configmap "${CM_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true

else
  # Local mode
  K6_CMD="k6"
  if ! command -v k6 >/dev/null 2>&1; then
    echo "[!] k6 binary not found in PATH! Falling back to docker run grafana/k6..."
    K6_CMD="docker run --rm -i --network=host -v ${SCRIPT_DIR}:/scripts grafana/k6"
  fi

  export TARGET_URL="${TARGET_URL}"
  export API_KEY="${API_KEY}"
  export API_SECRET="${API_SECRET}"
  export USER_EMAIL="${BENCH_USER}"
  export USER_PASSWORD="${BENCH_PASS}"
  export ENABLE_LOGIN="${ENABLE_LOGIN}"
  export WORKLOAD_TYPE="${WORKLOAD_TYPE}"
  export SCENARIO="${SCENARIO}"
  export VUS="${VUS}"
  export DURATION="${DURATION}"

  ${K6_CMD} run "${SCRIPT_DIR}/k6-workload.js" \
    --summary-export="${K6_SUMMARY_FILE}"
fi

# Step 4: Stop CPU monitoring
touch "${STOP_TRIGGER}"
echo "[4/5] Load test finished. Collecting final cooldown metrics..."
sleep 4

# Step 5: Correlation Analysis
echo "[5/5] Analyzing RPS vs CPU usage..."
python3 "${SCRIPT_DIR}/monitor_cpu.py" \
  --namespace "${NAMESPACE}" \
  --analyze-only "${CPU_SAMPLES_FILE}" \
  --k6-summary "${K6_SUMMARY_FILE}" \
  --report-json "${REPORT_JSON_FILE}"

# Step 6: Optional Cleanup
if [ "${DO_CLEANUP}" = "true" ]; then
  echo "[*] Cleaning up benchmark user and test records from bench..."
  kubectl exec -i -n "${NAMESPACE}" "${BENCH_POD}" -- \
    env BENCH_SITE="${SITE}" \
        BENCH_NUM_USERS="120" \
        BENCH_ACTION="cleanup" \
    /home/frappe/frappe-bench/env/bin/python3 - < "${SCRIPT_DIR}/setup_bench_user.py"
  echo "[+] Cleanup complete."
fi

# Remove temporary sensitive test user dump
rm -f "${USERS_JSON_FILE}"

echo "================================================================================"
echo " Experiment Complete! Full report saved to:"
echo " ${REPORT_JSON_FILE}"
echo "================================================================================"
