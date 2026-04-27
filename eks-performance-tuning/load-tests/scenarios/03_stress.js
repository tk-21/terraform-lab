/**
 * 03_stress.js — Stress Test (Breaking Point & Recovery)
 *
 * Purpose:
 *   Push the system to its breaking point (200 VU) and observe:
 *     - At what load errors begin to spike
 *     - Whether the system recovers after load is removed
 *     - How Karpenter / KEDA / HPA respond under extreme pressure
 *
 * Load Profile:
 *   Stage 1 :   0 → 200 VU over 2 min  (aggressive ramp)
 *   Stage 2 : 200 VU held for  3 min   (sustained peak)
 *   Stage 3 : 200 →   0 VU over 1 min  (recovery observation)
 *
 * Thresholds (intentionally loose — failure is expected and informative):
 *   - p95 latency < 10000ms
 *   - Error rate  < 50%
 *
 * Usage:
 *   BASE_URL=http://... k6 run --out json=results/stress.json 03_stress.js
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
    { duration: '2m', target: 200 },
    { duration: '3m', target: 200 },
    { duration: '1m', target: 0   },
  ],
  thresholds: {
    http_req_duration: ['p(95)<10000'],
    error_rate:        ['rate<0.5'],
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
  // Small sleep at the start of each iteration to avoid thundering herd
  // when all 200 VUs fire simultaneously at the beginning of each loop.
  sleep(0.1);

  // --- /cpu-intensive ---
  group('cpu-intensive', () => {
    const res = http.get(`${BASE_URL}/cpu-intensive`);
    check(res, { 'cpu status 200': (r) => r.status === 200 });
    cpuEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  sleep(0.1);

  // --- /memory-pressure ---
  group('memory-pressure', () => {
    const res = http.get(`${BASE_URL}/memory-pressure`);
    check(res, { 'mem status 200': (r) => r.status === 200 });
    memEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  sleep(0.1);

  // --- /db-latency ---
  group('db-latency', () => {
    const res = http.get(`${BASE_URL}/db-latency`);
    check(res, { 'db status 200': (r) => r.status === 200 });
    dbEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });
}
