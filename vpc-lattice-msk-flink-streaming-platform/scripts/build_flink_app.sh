#\!/bin/bash
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: bash scripts/build_flink_app.sh <S3_BUCKET_NAME>"
  exit 1
fi

S3_BUCKET="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "Building Flink application..."
cd "${PROJECT_ROOT}/flink-app"
mvn clean package -DskipTests

JAR_FILE="${PROJECT_ROOT}/flink-app/target/streaming-job-1.0.0.jar"

echo "Uploading to S3..."
aws s3 cp "${JAR_FILE}" "s3://${S3_BUCKET}/flink-app/streaming-job-1.0.0.jar"

echo "Upload complete: s3://${S3_BUCKET}/flink-app/streaming-job-1.0.0.jar"
