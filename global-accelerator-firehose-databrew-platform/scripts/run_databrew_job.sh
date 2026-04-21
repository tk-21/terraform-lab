#\!/bin/bash
set -euo pipefail

JOB_NAME="${1:-gaf-dev-job}"

echo "Starting DataBrew job: ${JOB_NAME}"
RUN_ID=$(aws databrew start-job-run --name "${JOB_NAME}" --query 'RunId' --output text)
echo "Job Run ID: ${RUN_ID}"

while true; do
  STATUS=$(aws databrew describe-job-run \
    --name "${JOB_NAME}" \
    --run-id "${RUN_ID}" \
    --query 'State' \
    --output text)
  echo "$(date '+%Y-%m-%dT%H:%M:%S') Status: ${STATUS}"

  case "${STATUS}" in
    SUCCEEDED)
      echo "Job completed successfully."
      break
      ;;
    FAILED|STOPPED)
      echo "Job ended with status: ${STATUS}"
      exit 1
      ;;
  esac

  sleep 30
done

BUCKET=$(aws databrew describe-job \
  --name "${JOB_NAME}" \
  --query 'Outputs[0].Location.Bucket' \
  --output text)
PREFIX=$(aws databrew describe-job \
  --name "${JOB_NAME}" \
  --query 'Outputs[0].Location.Key' \
  --output text)
echo "Output files in s3://${BUCKET}/${PREFIX}:"
aws s3 ls "s3://${BUCKET}/${PREFIX}" --recursive --human-readable
