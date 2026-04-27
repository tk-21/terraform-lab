/**
 * 01_baseline.js — Baseline Performance Recording
 *
 * Purpose:
 *   Record baseline performance metrics at a low, stable load level.
 *   Results serve as the reference point for all subsequent tuning comparisons.
 *
 * Load Profile:
 *   - VUs    : 10 (constant, no ramp)
 *   - Duration: 2 minutes
 *   - Pattern : Flat — all 3 endpoints called sequentially each iteration
 *
 * Thresholds:
 *   - p95 latency < 2000ms (permissive — we expect untuned behaviour)
 *   - Error rate  < 10%
 *
 * Usage:
 *   BASE_URL=http://... k6 run --out json=results/baseline.json 01_baseline.js
 */

import http from 'k6/http';
import { check, group } from 'k6';
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
  vus: 10,
  duration: '2m',
  thresholds: {
    http_req_duration: ['p(95)<2000'],
    error_rate:        ['rate<0.1'],
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

  // --- /memory-pressure ---
  group('memory-pressure', () => {
    const res = http.get(`${BASE_URL}/memory-pressure`);
    check(res, { 'mem status 200': (r) => r.status === 200 });
    memEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });

  // --- /db-latency ---
  group('db-latency', () => {
    const res = http.get(`${BASE_URL}/db-latency`);
    check(res, { 'db status 200': (r) => r.status === 200 });
    dbEndpointDuration.add(res.timings.duration);
    errorRate.add(res.status !== 200);
  });
}
