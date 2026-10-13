#!/usr/bin/env bash
#
# run_experiment.sh
# Automated, reproducible RPS per CPU benchmark for fayolex-working-staging.
#
# Usage:
#   ./run_experiment.sh [--mode k8s|local] [--vus 10] [--duration 45s] [--site demo.fayolex.co.id] [--login true|false] [--cleanup]
#

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "${RESULTS_DIR}"

MODE="k8s"
VUS="10"
DURATION="45s"
SITE="demo.fayolex.co.id"
ENABLE_LOGIN="true"
DO_CLEANUP="false"
STEPPED="false"
SCENARIO=""
WORKLOAD_TYPE="crud"
BENCH_USER="bench_loadtest_user@example.com"
BENCH_PASS="BenchPassword123!"

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --login)
      ENABLE_LOGIN="$2"; shift 2 ;;
    --cleanup)
      DO_CLEANUP="true"; shift 1 ;;
    --stepped)
      STEPPED="true"; shift 1 ;;
    --help|-h)
      echo "Usage: $0 [options]"
      echo "  --mode <k8s|local>    Run load generator in k8s (default) or locally"
      echo "  --vus <number>        Number of concurrent virtual users (default: 10)"
      echo "  --duration <time>     Benchmark duration e.g. 30s, 60s (default: 45s)"
      echo "  --scenario <shock|max> Preset scenario: 'shock' (morning surge) or 'max' (saturation push)"
      echo "  --site <hostname>     Frappe site name (default: demo.fayolex.co.id)"
      echo "  --login <true|false>  Include session login in workload (default: true)"
      echo "  --stepped             Run multi-stage test across 2, 5, 10, 20 VUs"
      echo "  --cleanup             Clean up dummy user and benchmark todos after run"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "================================================================================"
echo " Starting Benchmark Experiment for fayolex-working-staging"
echo " Mode: ${MODE} | VUs: ${VUS} | Duration: ${DURATION} | Site: ${SITE}"
echo "================================================================================"

# Verify kubectl access
if ! kubectl get ns fayolex-working-staging >/dev/null 2>&1; then
  echo "[!] Error: cannot access namespace fayolex-working-staging via kubectl"
  exit 1
fi

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RUN_ID="fayolex-working-staging-bench-${TIMESTAMP}"
STOP_TRIGGER="/tmp/bench_stop_${TIMESTAMP}"
CPU_SAMPLES_FILE="${RESULTS_DIR}/cpu_samples_${TIMESTAMP}.json"
K6_SUMMARY_FILE="${RESULTS_DIR}/k6_summary_${TIMESTAMP}.json"
REPORT_JSON_FILE="${RESULTS_DIR}/report_${TIMESTAMP}.json"

# Step 1: Instate dummy user and API key in Frappe bench pod
echo "[1/5] Instate dummy user and API keys in Frappe web pod..."
USER_SETUP_OUT=$(kubectl exec -i -n fayolex-working-staging deployment/web -- \
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

# Step 2: Start background CPU sampler to record baseline & under-load metrics
echo "[2/5] Starting pod CPU monitoring on fayolex-working-staging..."
rm -f "${STOP_TRIGGER}"
python3 "${SCRIPT_DIR}/monitor_cpu.py" \
  --output "${CPU_SAMPLES_FILE}" \
  --stop-trigger "${STOP_TRIGGER}" \
  --interval 2.0 > /dev/null 2>&1 &
MONITOR_PID=$!

echo "      Waiting 6s to establish idle baseline..."
sleep 6

# Step 3: Run the workload
echo "[3/5] Executing benchmark workload (Mode: ${MODE} | Scenario: ${SCENARIO:-custom})..."

if [ "${MODE}" = "k8s" ]; then
  JOB_NAME="fayolex-working-staging-benchmark-job"
  CM_NAME="fayolex-working-staging-benchmark-config"

  # Clean up any leftover job or configmap
  kubectl delete job "${JOB_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete configmap "${CM_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true

  # Create ConfigMap with the test script and user pool
  kubectl create configmap "${CM_NAME}" -n default \
    --from-file="k6-workload.js=${SCRIPT_DIR}/k6-workload.js" \
    --from-file="users.json=${USERS_JSON_FILE}" \
    --dry-run=client -o yaml | kubectl apply -n default -f - >/dev/null

  # Render Job manifest
  JOB_YAML="${RESULTS_DIR}/job_${TIMESTAMP}.yaml"
  cat "${SCRIPT_DIR}/k8s-job.yaml.template" | \
    sed "s|\${TARGET_URL}|https://${SITE}|g" | \
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
    POD_NAME=$(kubectl get pods -n default -l app.kubernetes.io/name=fayolex-working-staging-benchmark -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
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
    print('      [+] Extracted k6 summary JSON.')
else:
    print('      [!] Could not locate summary delimiters in logs.')
"

  # Clean up job and configmap
  kubectl delete job "${JOB_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true
  kubectl delete configmap "${CM_NAME}" -n default --ignore-not-found=true >/dev/null 2>&1 || true

else
  # Local mode
  if [ -n "${SCENARIO}" ]; then
    k6 run \
      -e TARGET_URL="https://${SITE}" \
      -e SCENARIO="${SCENARIO}" \
      -e ENABLE_LOGIN="${ENABLE_LOGIN}" \
      --summary-export="${K6_SUMMARY_FILE}" \
      "${SCRIPT_DIR}/k6-workload.js"
  else
    k6 run \
      -e TARGET_URL="https://${SITE}" \
      -e API_KEY="${API_KEY}" \
      -e API_SECRET="${API_SECRET}" \
      -e USER_EMAIL="${BENCH_USER}" \
      -e USER_PASSWORD="${BENCH_PASS}" \
      -e ENABLE_LOGIN="${ENABLE_LOGIN}" \
      --vus "${VUS}" \
      --duration "${DURATION}" \
      --summary-export="${K6_SUMMARY_FILE}" \
      "${SCRIPT_DIR}/k6-workload.js"
  fi
fi

# Step 4: Allow cooldown and stop CPU monitoring
echo "[4/5] Load test finished. Collecting final cooldown metrics..."
sleep 4
touch "${STOP_TRIGGER}"
wait "${MONITOR_PID}" 2>/dev/null || true
rm -f "${STOP_TRIGGER}"

# Step 5: Generate and print analysis report
echo "[5/5] Analyzing RPS vs CPU usage..."
python3 "${SCRIPT_DIR}/monitor_cpu.py" \
  --analyze-only \
  --output "${CPU_SAMPLES_FILE}" \
  --k6-summary "${K6_SUMMARY_FILE}" \
  --report-json "${REPORT_JSON_FILE}"

# Optional Cleanup
if [ "${DO_CLEANUP}" = "true" ]; then
  echo "[*] Cleaning up benchmark user and ToDos..."
  kubectl exec -i -n fayolex-working-staging deployment/web -- \
    env BENCH_SITE="${SITE}" \
        BENCH_EMAIL="${BENCH_USER}" \
        BENCH_ACTION="cleanup" \
    /home/frappe/frappe-bench/env/bin/python3 - < "${SCRIPT_DIR}/setup_bench_user.py" >/dev/null
  echo "      Cleanup complete."
fi

echo "================================================================================"
echo " Experiment Complete! Full report saved to:"
echo " ${REPORT_JSON_FILE}"
echo "================================================================================"
