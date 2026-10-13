import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter } from 'k6/metrics';

// Custom metrics for granular visibility
const cycleDuration = new Trend('crud_cycle_duration_ms');
const successfulCycles = new Counter('crud_cycles_success');
const failedCycles = new Counter('crud_cycles_failure');

// Read configuration from environment variables
const TARGET_URL = __ENV.TARGET_URL || 'https://demo.fayolex.co.id';
const API_KEY = __ENV.API_KEY || '';
const API_SECRET = __ENV.API_SECRET || '';
const USER_EMAIL = __ENV.USER_EMAIL || '';
const USER_PASSWORD = __ENV.USER_PASSWORD || '';
const ENABLE_LOGIN = __ENV.ENABLE_LOGIN === 'true' || __ENV.ENABLE_LOGIN === '1';
const SLEEP_MS = parseFloat(__ENV.SLEEP_MS || '0');
const WORKLOAD_TYPE = __ENV.WORKLOAD_TYPE || 'crud';

const scenarioConfig = {
  shock: {
    executor: 'ramping-vus',
    startVUs: 10,
    stages: [
      { duration: '10s', target: 10 },  // Baseline calm before rush
      { duration: '2s', target: 80 },   // Instantaneous synchronized shock!
      { duration: '35s', target: 80 },  // Sustained peak rush
      { duration: '10s', target: 10 },  // Ramp-down recovery
    ],
    gracefulRampDown: '5s',
  },
  burst: {
    executor: 'constant-vus',
    vus: 80,
    duration: '60s',
    gracefulStop: '5s',
  },
  max: {
    executor: 'ramping-vus',
    startVUs: 20,
    stages: [
      { duration: '15s', target: 20 },  // Warm-up baseline
      { duration: '15s', target: 50 },  // Stepping load
      { duration: '20s', target: 80 },  // High load
      { duration: '30s', target: 120 }, // Max saturation push
      { duration: '10s', target: 10 },  // Ramp-down recovery
    ],
    gracefulRampDown: '5s',
  },
};

const baseOptions = {
  insecureSkipTLSVerify: true,
  discardResponseBodies: false,
  thresholds: {
    http_req_failed: ['rate<0.05'], // Allow < 5% failure under extreme load
  },
};

if (__ENV.SCENARIO && scenarioConfig[__ENV.SCENARIO]) {
  baseOptions.scenarios = {
    [__ENV.SCENARIO]: scenarioConfig[__ENV.SCENARIO],
  };
}

export const options = baseOptions;

let userPool = [];
try {
  userPool = JSON.parse(open('/scripts/users.json'));
} catch (e) {
  try {
    userPool = JSON.parse(open('./users.json'));
  } catch (e2) {
    if (__ENV.USER_POOL_JSON) {
      try { userPool = JSON.parse(__ENV.USER_POOL_JSON); } catch (e3) {}
    }
  }
}

export default function () {
  const cycleStart = Date.now();
  let cycleSuccess = true;

  let currentEmail = USER_EMAIL;
  let currentPassword = USER_PASSWORD;
  let currentApiKey = API_KEY;
  let currentApiSecret = API_SECRET;

  if (userPool && userPool.length > 0) {
    const u = userPool[(__VU - 1) % userPool.length];
    currentEmail = u.email;
    currentPassword = u.password;
    currentApiKey = u.api_key;
    currentApiSecret = u.api_secret;
  }

  const authHeaders = {
    'Content-Type': 'application/json',
    'Accept': 'application/json',
  };

  if (currentApiKey && currentApiSecret) {
    authHeaders['Authorization'] = `token ${currentApiKey}:${currentApiSecret}`;
  }

  // Mode 1: Pure Read Workload (GET list)
  if (WORKLOAD_TYPE === 'read') {
    const res = http.get(`${TARGET_URL}/api/resource/ToDo?limit=10`, {
      headers: authHeaders,
      tags: { endpoint: 'list_todo' },
    });
    const ok = check(res, { 'status is 200': (r) => r.status === 200 });
    if (!ok) cycleSuccess = false;

    if (cycleSuccess) successfulCycles.add(1);
    else failedCycles.add(1);

    if (SLEEP_MS > 0) sleep(SLEEP_MS / 1000);
    return;
  }

  // Mode 2: Pure Write Workload (POST /api/resource/ToDo)
  if (WORKLOAD_TYPE === 'write') {
    const payload = JSON.stringify({
      description: `Benchmark pure write [VU ${__VU} iter ${__ITER} ${Date.now()}]`,
      status: 'Open',
      priority: 'Medium',
    });
    const res = http.post(`${TARGET_URL}/api/resource/ToDo`, payload, {
      headers: authHeaders,
      tags: { endpoint: 'create_todo' },
    });
    const ok = check(res, { 'status is 200': (r) => r.status === 200 });
    if (!ok) cycleSuccess = false;

    if (cycleSuccess) successfulCycles.add(1);
    else failedCycles.add(1);

    if (SLEEP_MS > 0) sleep(SLEEP_MS / 1000);
    return;
  }

  // Mode 3: Pure Update Workload (Fetch latest or update existing)
  if (WORKLOAD_TYPE === 'update') {
    // Read one item to get its name, then update it
    const listRes = http.get(`${TARGET_URL}/api/resource/ToDo?limit=1&order_by=creation%20desc`, {
      headers: authHeaders,
      tags: { endpoint: 'get_target_for_update' },
    });
    let targetName = null;
    if (listRes.status === 200) {
      try {
        const items = listRes.json('data');
        if (items && items.length > 0) targetName = items[0].name;
      } catch (e) {}
    }

    if (targetName) {
      const updatePayload = JSON.stringify({
        description: `Benchmark pure update [VU ${__VU} iter ${__ITER} ${Date.now()}]`,
      });
      const updateRes = http.put(`${TARGET_URL}/api/resource/ToDo/${targetName}`, updatePayload, {
        headers: authHeaders,
        tags: { endpoint: 'update_todo' },
      });
      const ok = check(updateRes, { 'status is 200': (r) => r.status === 200 });
      if (!ok) cycleSuccess = false;
    } else {
      cycleSuccess = false;
    }

    if (cycleSuccess) successfulCycles.add(1);
    else failedCycles.add(1);

    if (SLEEP_MS > 0) sleep(SLEEP_MS / 1000);
    return;
  }

  // Mode 4: Realistic 80% Read / 20% Write-Update (80% read, 10% insert, 10% update)
  if (WORKLOAD_TYPE === 'mix8020' || WORKLOAD_TYPE === 'mixed') {
    const rand = Math.random();
    if (rand < 0.80) {
      // 80% Read
      const res = http.get(`${TARGET_URL}/api/resource/ToDo?limit=10`, {
        headers: authHeaders,
        tags: { endpoint: 'list_todo' },
      });
      const ok = check(res, { 'status is 200': (r) => r.status === 200 });
      if (!ok) cycleSuccess = false;
    } else if (rand < 0.90) {
      // 10% Write
      const payload = JSON.stringify({
        description: `Benchmark mixed write [VU ${__VU} iter ${__ITER}]`,
        status: 'Open',
        priority: 'Medium',
      });
      const res = http.post(`${TARGET_URL}/api/resource/ToDo`, payload, {
        headers: authHeaders,
        tags: { endpoint: 'create_todo' },
      });
      const ok = check(res, { 'status is 200': (r) => r.status === 200 });
      if (!ok) cycleSuccess = false;
    } else {
      // 10% Update
      const listRes = http.get(`${TARGET_URL}/api/resource/ToDo?limit=1&order_by=creation%20desc`, {
        headers: authHeaders,
        tags: { endpoint: 'get_target_for_update' },
      });
      let targetName = null;
      if (listRes.status === 200) {
        try {
          const items = listRes.json('data');
          if (items && items.length > 0) targetName = items[0].name;
        } catch (e) {}
      }
      if (targetName) {
        const updatePayload = JSON.stringify({
          description: `Benchmark mixed update [VU ${__VU} iter ${__ITER}]`,
        });
        const updateRes = http.put(`${TARGET_URL}/api/resource/ToDo/${targetName}`, updatePayload, {
          headers: authHeaders,
          tags: { endpoint: 'update_todo' },
        });
        const ok = check(updateRes, { 'status is 200': (r) => r.status === 200 });
        if (!ok) cycleSuccess = false;
      }
    }

    if (cycleSuccess) successfulCycles.add(1);
    else failedCycles.add(1);

    if (SLEEP_MS > 0) sleep(SLEEP_MS / 1000);
    return;
  }

  // 1. Optional Session Login (Simulates interactive web user)
  if (ENABLE_LOGIN && currentEmail && currentPassword) {
    const loginPayload = JSON.stringify({
      usr: currentEmail,
      pwd: currentPassword,
    });
    const loginRes = http.post(`${TARGET_URL}/api/method/login`, loginPayload, {
      headers: { 'Content-Type': 'application/json' },
      tags: { endpoint: 'login' },
    });
    const loginOk = check(loginRes, {
      'login status is 200': (r) => r.status === 200,
    });
    if (!loginOk) cycleSuccess = false;
  }

  // 2. CREATE ToDo
  const createPayload = JSON.stringify({
    description: `Benchmark test task [VU ${__VU} iter ${__ITER}]`,
    status: 'Open',
    priority: 'Medium',
  });
  const createRes = http.post(`${TARGET_URL}/api/resource/ToDo`, createPayload, {
    headers: authHeaders,
    tags: { endpoint: 'create_todo' },
  });
  const createOk = check(createRes, {
    'create_todo status is 200': (r) => r.status === 200,
  });

  let todoId = null;
  if (createOk) {
    try {
      const data = createRes.json('data');
      if (data && data.name) {
        todoId = data.name;
      }
    } catch (e) {
      cycleSuccess = false;
    }
  } else {
    cycleSuccess = false;
  }

  // 3. READ ToDo (by name)
  if (todoId) {
    const readRes = http.get(`${TARGET_URL}/api/resource/ToDo/${todoId}`, {
      headers: authHeaders,
      tags: { endpoint: 'read_todo' },
    });
    const readOk = check(readRes, {
      'read_todo status is 200': (r) => r.status === 200,
    });
    if (!readOk) cycleSuccess = false;

    // 4. UPDATE ToDo
    const updatePayload = JSON.stringify({
      description: `Benchmark test task [VU ${__VU} iter ${__ITER}] - Updated`,
      status: 'Closed',
    });
    const updateRes = http.put(`${TARGET_URL}/api/resource/ToDo/${todoId}`, updatePayload, {
      headers: authHeaders,
      tags: { endpoint: 'update_todo' },
    });
    const updateOk = check(updateRes, {
      'update_todo status is 200': (r) => r.status === 200,
    });
    if (!updateOk) cycleSuccess = false;

    // 5. LIST ToDos (Query list endpoint)
    const listRes = http.get(`${TARGET_URL}/api/resource/ToDo?limit=10`, {
      headers: authHeaders,
      tags: { endpoint: 'list_todo' },
    });
    const listOk = check(listRes, {
      'list_todo status is 200': (r) => r.status === 200,
    });
    if (!listOk) cycleSuccess = false;

    // 6. DELETE ToDo (Cleanup)
    const delRes = http.del(`${TARGET_URL}/api/resource/ToDo/${todoId}`, null, {
      headers: authHeaders,
      tags: { endpoint: 'delete_todo' },
    });
    const delOk = check(delRes, {
      'delete_todo status is 200 or 202': (r) => r.status === 200 || r.status === 202,
    });
    if (!delOk) cycleSuccess = false;
  }

  const cycleTime = Date.now() - cycleStart;
  cycleDuration.add(cycleTime);

  if (cycleSuccess) {
    successfulCycles.add(1);
  } else {
    failedCycles.add(1);
  }

  if (SLEEP_MS > 0) {
    sleep(SLEEP_MS / 1000);
  }
}
