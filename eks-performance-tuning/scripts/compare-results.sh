#\!/usr/bin/env bash
# Usage: compare-results.sh <BEFORE_FILE> <AFTER_FILE>
#
# Compares two k6 result JSON files (before and after tuning) and prints a
# markdown table showing latency and throughput metrics with % improvement.
#
# Arguments:
#   BEFORE_FILE  Path to the baseline result JSON (e.g. load-tests/results/baseline_20240101_120000.json)
#   AFTER_FILE   Path to the post-tuning result JSON
#
# Output:
#   Markdown table with p95, p99, avg latency, and RPS before/after/improvement
#
# Requirements:
#   - jq must be installed

set -euo pipefail

# --- Help ---
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
  sed -n '2,16p' "$0" | grep '^#' | sed 's/^# \?//'
  exit 0
fi

# --- Validate args ---
if [[ $# -ne 2 ]]; then
  echo "Error: exactly 2 arguments required." >&2
  echo "Usage: $0 <BEFORE_FILE> <AFTER_FILE>" >&2
  exit 1
fi

BEFORE_FILE="$1"
AFTER_FILE="$2"

for f in "$BEFORE_FILE" "$AFTER_FILE"; do
  if [[ \! -f "$f" ]]; then
    echo "Error: file not found: $f" >&2
    exit 1
  fi
done

if \! command -v jq &>/dev/null; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

# --- Extract metrics ---
extract_latency() {
  local file="$1"
  local quantile="$2"
  jq -r --arg q "$quantile" \
    '.metrics["http_req_duration"]["values"][$q] // 0' "$file" 2>/dev/null || echo "0"
}

extract_rps() {
  local file="$1"
  jq -r '.metrics["http_reqs"]["values"]["rate"] // 0' "$file" 2>/dev/null || echo "0"
}

# For latency: improvement = (before - after) / before * 100  (lower is better)
pct_latency_improvement() {
  local before="$1"
  local after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN {
    if (b+0 == 0) { print "N/A"; exit }
    val = (b - a) / b * 100
    if (val >= 0)
      printf "+%.1f%%", val
    else
      printf "%.1f%%", val
  }'
}

# For RPS: improvement = (after - before) / before * 100  (higher is better)
pct_rps_improvement() {
  local before="$1"
  local after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN {
    if (b+0 == 0) { print "N/A"; exit }
    val = (a - b) / b * 100
    if (val >= 0)
      printf "+%.1f%%", val
    else
      printf "%.1f%%", val
  }'
}

round2() {
  awk -v v="$1" 'BEGIN { printf "%.2f", v+0 }'
}

BEFORE_P95=$(extract_latency "$BEFORE_FILE" "p(95)")
BEFORE_P99=$(extract_latency "$BEFORE_FILE" "p(99)")
BEFORE_AVG=$(extract_latency "$BEFORE_FILE" "avg")
BEFORE_RPS=$(extract_rps "$BEFORE_FILE")

AFTER_P95=$(extract_latency "$AFTER_FILE" "p(95)")
AFTER_P99=$(extract_latency "$AFTER_FILE" "p(99)")
AFTER_AVG=$(extract_latency "$AFTER_FILE" "avg")
AFTER_RPS=$(extract_rps "$AFTER_FILE")

# --- Print report ---
echo "## Benchmark Comparison Report"
echo ""
echo "| Baseline file  | \`${BEFORE_FILE}\` |"
echo "| After file     | \`${AFTER_FILE}\` |"
echo ""
echo "| Metric       | Before (ms/rps)       | After (ms/rps)        | Improvement       |"
echo "|:-------------|----------------------:|----------------------:|------------------:|"
echo "| p95 (ms)     | $(round2 "$BEFORE_P95") | $(round2 "$AFTER_P95") | $(pct_latency_improvement "$BEFORE_P95" "$AFTER_P95") |"
echo "| p99 (ms)     | $(round2 "$BEFORE_P99") | $(round2 "$AFTER_P99") | $(pct_latency_improvement "$BEFORE_P99" "$AFTER_P99") |"
echo "| avg (ms)     | $(round2 "$BEFORE_AVG") | $(round2 "$AFTER_AVG") | $(pct_latency_improvement "$BEFORE_AVG" "$AFTER_AVG") |"
echo "| RPS          | $(round2 "$BEFORE_RPS") | $(round2 "$AFTER_RPS") | $(pct_rps_improvement "$BEFORE_RPS" "$AFTER_RPS") |"
echo ""
echo "> Latency improvement: positive = faster (lower latency). RPS improvement: positive = higher throughput."
