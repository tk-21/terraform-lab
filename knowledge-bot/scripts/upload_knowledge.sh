#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DOCS_DIR="${ROOT_DIR}/docs"

# default: keep remote files (no delete)
DELETE_FLAG="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)
      DELETE_FLAG="true"
      shift
      ;;
    --docs-dir)
      DOCS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/upload_knowledge.sh [--delete] [--docs-dir <path>]

Options:
  --delete           Delete objects in S3 that are not present locally.
  --docs-dir <path>  Local docs directory to upload (default: ./docs).
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "Docs directory not found: $DOCS_DIR" >&2
  exit 1
fi

cd "$ROOT_DIR/infra"
BUCKET="$(terraform output -raw knowledge_bucket)"
REGION="$(terraform output -raw region)"

if [[ -z "$BUCKET" || "$BUCKET" == "null" ]]; then
  echo "knowledge_bucket is empty. Run terraform apply first." >&2
  exit 1
fi

SYNC_ARGS=(s3 sync "$DOCS_DIR" "s3://$BUCKET/docs/" --region "$REGION")
if [[ "$DELETE_FLAG" == "true" ]]; then
  SYNC_ARGS+=(--delete)
fi

echo "[*] Upload docs -> s3://$BUCKET/docs/"
aws "${SYNC_ARGS[@]}"

echo "[*] Done"
echo "    bucket: $BUCKET"
echo "    region: $REGION"
echo "    docs:   $DOCS_DIR"
