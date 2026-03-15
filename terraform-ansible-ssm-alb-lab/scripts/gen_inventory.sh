#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${TF_DIR:-$ROOT_DIR/terraform/envs/dev}"
INV_FILE="$ROOT_DIR/ansible/inventories/dev/hosts.yml"
REGION="${REGION:-ap-northeast-1}"

cd "$TF_DIR"
if [[ ! -d ".terraform" ]]; then
  terraform init -input=false >/dev/null
fi

INSTANCE_ID="$(terraform output -raw instance_id)"
BUCKET_NAME="$(terraform output -raw ssm_transfer_bucket)"

mkdir -p "$(dirname "$INV_FILE")"

cat > "$INV_FILE" <<YAML
all:
  hosts:
    ${INSTANCE_ID}:
      ansible_connection: amazon.aws.aws_ssm
      ansible_aws_ssm_region: ${REGION}
      ansible_aws_ssm_bucket_name: ${BUCKET_NAME}
YAML

echo "Generated SSM inventory: $INV_FILE"
echo "  instance_id(hostname): ${INSTANCE_ID}"
echo "  bucket: ${BUCKET_NAME}"
