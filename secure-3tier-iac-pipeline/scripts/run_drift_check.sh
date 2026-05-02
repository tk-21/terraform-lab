#!/bin/bash
# ドリフト検出専用スクリプト (定期実行想定)
set -euo pipefail

cd "$(dirname "$0")/../ansible"
ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file "${VAULT_PASSWORD_FILE:-~/.vault_pass}" \
  --check \
  --diff \
  drift_check.yml
