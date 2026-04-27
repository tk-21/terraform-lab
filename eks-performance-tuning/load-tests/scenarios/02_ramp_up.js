/**
 * 02_ramp_up.js — Ramp-Up Load Test
 *
 * Purpose:
 *   Identify the load level at which performance begins to degrade.
 *   Gradually increases VUs from 10 → 50 → 100 and then ramps down.
 *   Compare p95 latency and error rate against the 01_baseline results.
 *
 * Load Profile:
 *   Stage 1 :  0 →  10 VU over 1 min  (warm-up)
 *   Stage 2 : 10 →  50 VU over 2 min  (moderate load)
 *   Stage 3 : 50 → 100 VU over 2 min  (high load)
 *   Stage 4 :100 →   0 VU over 1 min  (cool-down)
 *
 * Thresholds (strict — degradation should be visible):
 *   - p95 latency < 500ms
 *   - Error rate  < 1%
 *
 * Usage:
 *   BASE_URL=http://... k6 run --out json=results/ramp_up.json 02_ramp_up.js
 */

import http from 'k6/http';
import { check, group, sleep } from 'k6';
import { Trend, Rate } from 'k6/metrics';

// ---------------------------------------------------------------------------
// Custom metrics
// ---------------------------------------------------------------------------
const cpuEndpointDuration = new Trend('cpu_endpoint_duration', true);
const memEndpointDuration = new Trend('mem_endpoint_duration', true);
const dbEndpointDuration  = new Trend('db_endpoint_duration', true);
const errorRate           = new Rate('error_rate');

// ---------------------------------------------------------------------------
// Options
// ---------------------------------------------------------------------------
export const options = {
  stages: [
    { duration: '1m', target: 10  },
    { duration: '2m', target: 50  },
    { duration: '2m', target: 100 },
    { duration: '1m', target: 0   },
  ],
  thresholds: {
    http_req_duration: ['p(95)<500'],
    error_rate:        ['rate<0.01'],
  },
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
const BASE_URL = __ENV.BASE_URL || 'http://sample-app.perf-tuning.svc.cluster.local';

// ---------------------------------------------------------------------------
// Default function
// ---------------------------------------------------------------------------
export default function () {
  // --- /cpu-intensive ---
  group('cpu-intensive', () => {
    const res = http.get(`${BASE_URL}/cpu-intensive`);
    check(res, { 'cpu status 200': (r) => r.status === 200 });
    cpuEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  sleep(1);

  // --- /memory-pressure ---
  group('memory-pressure', () => {
    const res = http.get(`${BASE_URL}/memory-pressure`);
    check(res, { 'mem status 200': (r) => r.status === 200 });
    memEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  sleep(1);

  // --- /db-latency ---
  group('db-latency', () => {
    const res = http.get(`${BASE_URL}/db-latency`);
    check(res, { 'db status 200': (r) => r.status === 200 });
    dbEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  sleep(1);
}
