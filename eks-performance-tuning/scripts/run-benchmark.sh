#\!/usr/bin/env bash
# run-benchmark.sh - Run k6 load test on ECS Fargate and save results
#
# Usage:
#   ./run-benchmark.sh <scenario> <tag>
#   Example: ./run-benchmark.sh 01_baseline before-tuning
#
# Required environment variables:
#   K6_S3_BUCKET       - S3 bucket for k6 scripts and results
#   K6_ECS_CLUSTER     - ECS cluster name or ARN
#   K6_TASK_DEFINITION - ECS task definition name or ARN
#   K6_SUBNET_IDS      - Comma-separated subnet IDs for Fargate task (e.g. subnet-aaa,subnet-bbb)
#   APP_BASE_URL       - Base URL of the application under test
#
# NOTE: The k6 container image must include a wrapper entrypoint that uploads
#       /tmp/result.json to s3://${K6_S3_BUCKET}/results/${TAG}/${SCENARIO}_result.json
#       after k6 finishes. Without this sidecar upload step, result download will fail.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
  echo "Usage: $0 <scenario> <tag>"
  echo ""
  echo "  scenario  k6 scenario name (filename without .js, e.g. 01_baseline)"
  echo "  tag       label for this run (e.g. before-tuning, after-tuning)"
  echo ""
  echo "Required environment variables:"
  echo "  K6_S3_BUCKET       S3 bucket for k6 scripts and results"
  echo "  K6_ECS_CLUSTER     ECS cluster name or ARN"
  echo "  K6_TASK_DEFINITION ECS task definition name or ARN"
  echo "  K6_SUBNET_IDS      Comma-separated subnet IDs for Fargate task"
  echo "  APP_BASE_URL       Base URL of the application under test"
  exit 1
}

# ---------------------------------------------------------------------------
# Step 1: Validate positional args
# ---------------------------------------------------------------------------
if [[ $# -ne 2 ]]; then
  echo "ERROR: Exactly 2 arguments required." >&2
  echo "" >&2
  usage
fi

SCENARIO="$1"
TAG="$2"

# ---------------------------------------------------------------------------
# Step 2: Validate required environment variables
# ---------------------------------------------------------------------------
check_env_vars() {
  local missing=0
  for var in K6_S3_BUCKET K6_ECS_CLUSTER K6_TASK_DEFINITION K6_SUBNET_IDS APP_BASE_URL; do
    if [[ -z "${\!var:-}" ]]; then
      echo "ERROR: Required environment variable '${var}' is not set." >&2
      missing=1
    fi
  done
  if [[ $missing -ne 0 ]]; then
    echo "" >&2
    echo "Please set all required environment variables before running this script." >&2
    exit 1
  fi
}
check_env_vars

# ---------------------------------------------------------------------------
# Step 3: Check jq availability
# ---------------------------------------------------------------------------
HAS_JQ=false
if command -v jq &>/dev/null; then
  HAS_JQ=true
else
  echo "WARNING: jq is not installed. Falling back to python3 for JSON parsing. Summary output will be limited." >&2
fi

# Helper: extract a value from JSON using jq or python3
json_get() {
  local json="$1"
  local jq_filter="$2"
  local python_expr="$3"
  if [[ "$HAS_JQ" == true ]]; then
    echo "$json" | jq -r "$jq_filter"
  else
    echo "$json" | python3 -c "$python_expr"
  fi
}

# ---------------------------------------------------------------------------
# Step 4: Upload k6 script to S3
# ---------------------------------------------------------------------------
K6_SCRIPT="${REPO_ROOT}/load-tests/scenarios/${SCENARIO}.js"
if [[ \! -f "$K6_SCRIPT" ]]; then
  echo "ERROR: k6 script not found: ${K6_SCRIPT}" >&2
  exit 1
fi

echo "[1/5] Uploading k6 script to S3..."
aws s3 cp "$K6_SCRIPT" "s3://${K6_S3_BUCKET}/scripts/${SCENARIO}.js"
echo "      Uploaded: s3://${K6_S3_BUCKET}/scripts/${SCENARIO}.js"

# ---------------------------------------------------------------------------
# Step 5: Start ECS Fargate task
# ---------------------------------------------------------------------------
echo "[2/5] Starting ECS Fargate task..."

# Convert comma-separated subnet IDs to the format ECS expects: subnet-aaa,subnet-bbb
SUBNETS="$(echo "$K6_SUBNET_IDS" | tr -d ' ')"

OVERRIDES="$(cat <<OVERRIDES_EOF
{
  "containerOverrides": [
    {
      "name": "k6",
      "command": ["run", "--out", "json=/tmp/result.json", "/scripts/${SCENARIO}.js"],
      "environment": [
        {"name": "BASE_URL", "value": "${APP_BASE_URL}"},
        {"name": "SCENARIO", "value": "${SCENARIO}"},
        {"name": "S3_BUCKET", "value": "${K6_S3_BUCKET}"}
      ]
    }
  ]
}
OVERRIDES_EOF
)"

RUN_TASK_OUTPUT="$(aws ecs run-task \
  --cluster "$K6_ECS_CLUSTER" \
  --task-definition "$K6_TASK_DEFINITION" \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],assignPublicIp=DISABLED}" \
  --overrides "$OVERRIDES")"

TASK_ARN="$(json_get "$RUN_TASK_OUTPUT" \
  '.tasks[0].taskArn' \
  "import sys,json; data=json.load(sys.stdin); print(data['tasks'][0]['taskArn'])")"

if [[ -z "$TASK_ARN" || "$TASK_ARN" == "null" ]]; then
  echo "ERROR: Failed to get task ARN from ECS run-task response." >&2
  echo "$RUN_TASK_OUTPUT" >&2
  exit 1
fi
echo "      Task ARN: ${TASK_ARN}"

# ---------------------------------------------------------------------------
# Step 6: Wait for task completion (poll every 15s, timeout 30 minutes)
# ---------------------------------------------------------------------------
echo -n "[3/5] Waiting for task to complete"

wait_for_task() {
  local max_polls=120  # 120 x 15s = 30 minutes
  local poll_count=0
  local last_status=""
  local describe_output=""

  while [[ $poll_count -lt $max_polls ]]; do
    sleep 15

    describe_output="$(aws ecs describe-tasks \
      --cluster "$K6_ECS_CLUSTER" \
      --tasks "$TASK_ARN")"

    last_status="$(json_get "$describe_output" \
      '.tasks[0].lastStatus' \
      "import sys,json; data=json.load(sys.stdin); print(data['tasks'][0]['lastStatus'])")"

    printf '.'
    poll_count=$((poll_count + 1))

    if [[ "$last_status" == "STOPPED" ]]; then
      echo ""
      echo "      Task stopped after $((poll_count * 15))s."
      FINAL_DESCRIBE_OUTPUT="$describe_output"
      return 0
    fi
  done

  echo "" >&2
  echo "ERROR: Timed out waiting for ECS task to complete after 30 minutes." >&2
  exit 1
}

FINAL_DESCRIBE_OUTPUT=""
wait_for_task

# ---------------------------------------------------------------------------
# Step 7: Check container exit code
# ---------------------------------------------------------------------------
echo "[4/5] Checking task exit code..."

EXIT_CODE="$(json_get "$FINAL_DESCRIBE_OUTPUT" \
  '.tasks[0].containers[0].exitCode' \
  "import sys,json; data=json.load(sys.stdin); print(data['tasks'][0]['containers'][0]['exitCode'])")"

if [[ "$EXIT_CODE" \!= "0" ]]; then
  echo "ERROR: k6 container exited with code ${EXIT_CODE}. Load test failed." >&2
  exit 1
fi
echo "      Container exited successfully (exit code 0)."

# ---------------------------------------------------------------------------
# Step 8: Download results from S3
# NOTE: This step requires the k6 container image to include a wrapper entrypoint
#       that uploads /tmp/result.json to:
#         s3://${K6_S3_BUCKET}/results/${TAG}/${SCENARIO}_result.json
#       after k6 finishes. A simple wrapper entrypoint example:
#         #\!/bin/sh
#         k6 "$@"
#         aws s3 cp /tmp/result.json "s3://${S3_BUCKET}/results/${TAG}/${SCENARIO}_result.json"
#       where S3_BUCKET, TAG, and SCENARIO are injected via ECS task override environment.
# ---------------------------------------------------------------------------
echo "[5/5] Downloading results from S3..."

S3_RESULT_PATH="s3://${K6_S3_BUCKET}/results/${TAG}/${SCENARIO}_result.json"
LOCAL_RESULT_DIR="${REPO_ROOT}/load-tests/results/${TAG}"
LOCAL_RESULT_FILE="${LOCAL_RESULT_DIR}/${SCENARIO}_result.json"

mkdir -p "$LOCAL_RESULT_DIR"

RESULT_FILE=""
if aws s3 cp "$S3_RESULT_PATH" "$LOCAL_RESULT_FILE" 2>/dev/null; then
  RESULT_FILE="$LOCAL_RESULT_FILE"
  echo "      Download complete."
else
  echo "WARNING: Could not download results from ${S3_RESULT_PATH}" >&2
  echo "WARNING: Ensure the k6 container image uploads /tmp/result.json to S3 after the test completes." >&2
  echo "WARNING: Expected S3 path: ${S3_RESULT_PATH}" >&2
fi

# ---------------------------------------------------------------------------
# Step 9: Print summary
# ---------------------------------------------------------------------------
echo ""
if [[ -n "$RESULT_FILE" && "$HAS_JQ" == true ]]; then
  echo "=== Load Test Summary ==="
  P50="$(jq -r '.metrics.http_req_duration.values["p(50)"] // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
  P95="$(jq -r '.metrics.http_req_duration.values["p(95)"] // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
  P99="$(jq -r '.metrics.http_req_duration.values["p(99)"] // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
  ERROR_RATE="$(jq -r 'if .metrics.http_req_failed.values.rate then (.metrics.http_req_failed.values.rate * 100 | tostring) + "%" else "N/A" end' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
  ITERATIONS="$(jq -r '.metrics.iterations.values.count // "N/A"' "$RESULT_FILE" 2>/dev/null || echo 'N/A')"
  printf "  %-28s %s ms\n" "http_req_duration p50:" "$P50"
  printf "  %-28s %s ms\n" "http_req_duration p95:" "$P95"
  printf "  %-28s %s ms\n" "http_req_duration p99:" "$P99"
  printf "  %-28s %s\n"   "error rate:"             "$ERROR_RATE"
  printf "  %-28s %s\n"   "iterations:"             "$ITERATIONS"
  echo "========================="
  echo ""
  echo "Results saved to: ${RESULT_FILE}"
elif [[ -n "$RESULT_FILE" ]]; then
  echo "Results saved to: ${RESULT_FILE}"
fi

echo "Benchmark complete. Scenario: ${SCENARIO}, Tag: ${TAG}"
