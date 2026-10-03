#!/bin/bash
# ドリフト検出専用スクリプト (定期実行想定)
set -euo pipefail

cd "$(dirname "$0")/../ansible"

# [設計意図] アカウントIDはリポジトリに書かず、未設定なら STS から取得して Ansible に渡す
export AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"

ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file "${VAULT_PASSWORD_FILE:-~/.vault_pass}" \
  --check \
  --diff \
  drift_check.yml
