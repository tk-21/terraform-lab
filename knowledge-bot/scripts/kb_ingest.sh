#!/usr/bin/env bash
set -euo pipefail

tf() { (cd infra && terraform output -raw "$1"); }

WAIT_MODE="true"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1800}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait)
      WAIT_MODE="false"
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/kb_ingest.sh [--no-wait]

Options:
  --no-wait   Start ingestion job and exit immediately.

Environment variables:
  POLL_INTERVAL   Poll interval seconds when waiting (default: 10)
  TIMEOUT_SECONDS Max wait time seconds (default: 1800)
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

REGION="$(tf region)"
KB_ID="$(tf knowledge_base_id)"
DS_ID="$(tf data_source_id)"

# terraform output が "ID1,ID2" のように複数返る環境があるため、
# StartIngestionJob には有効な10文字IDを1つだけ渡す。
DS_ID="$(echo "$DS_ID" | tr ',' '\n' | awk '/^[0-9A-Za-z]{10}$/{print; exit}')"

if [[ -z "${KB_ID}" || "${KB_ID}" == "null" ]]; then
  echo "Knowledge Base not provisioned. Skip."
  exit 0
fi

if [[ -z "${DS_ID}" || "${DS_ID}" == "null" ]]; then
  echo "Data Source not provisioned. Skip."
  exit 0
fi

JOB_ID="$(aws bedrock-agent start-ingestion-job \
  --region "$REGION" \
  --knowledge-base-id "$KB_ID" \
  --data-source-id "$DS_ID" \
  --query 'ingestionJob.ingestionJobId' \
  --output text)"

echo "Started ingestion job: KB=${KB_ID} DS=${DS_ID} JOB=${JOB_ID}"

if [[ "${WAIT_MODE}" != "true" ]]; then
  exit 0
fi

echo "[*] Waiting for ingestion to complete..."
start_ts="$(date +%s)"

while true; do
  STATUS="$(aws bedrock-agent get-ingestion-job \
    --region "$REGION" \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS_ID" \
    --ingestion-job-id "$JOB_ID" \
    --query 'ingestionJob.status' \
    --output text)"

  STATS="$(aws bedrock-agent get-ingestion-job \
    --region "$REGION" \
    --knowledge-base-id "$KB_ID" \
    --data-source-id "$DS_ID" \
    --ingestion-job-id "$JOB_ID" \
    --query 'ingestionJob.statistics' \
    --output json)"

  now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$now] status=${STATUS} stats=${STATS}"

  case "$STATUS" in
    COMPLETE)
      echo "[*] Ingestion completed."
      exit 0
      ;;
    FAILED|STOPPED)
      echo "[!] Ingestion failed or stopped."
      aws bedrock-agent get-ingestion-job \
        --region "$REGION" \
        --knowledge-base-id "$KB_ID" \
        --data-source-id "$DS_ID" \
        --ingestion-job-id "$JOB_ID"
      exit 1
      ;;
  esac

  elapsed="$(( $(date +%s) - start_ts ))"
  if [[ "$elapsed" -ge "$TIMEOUT_SECONDS" ]]; then
    echo "[!] Timeout waiting for ingestion job completion (${TIMEOUT_SECONDS}s)."
    exit 124
  fi

  sleep "$POLL_INTERVAL"
done
