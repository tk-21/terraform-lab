#!/bin/bash
# SSM Session Manager 経由での Ansible 実行スクリプト
set -euo pipefail

PLAYBOOK="${1:-site.yml}"
VAULT_PASSWORD_FILE="${VAULT_PASSWORD_FILE:-~/.vault_pass}"
ANSIBLE_DIR="$(cd "$(dirname "$0")/../ansible" && pwd)"

echo "=== Ansible 実行開始: ${PLAYBOOK} ==="
echo "対象環境: prod (ap-northeast-1)"

echo "--- インベントリ確認 ---"
cd "${ANSIBLE_DIR}"
ansible-inventory -i inventories/aws_ec2.yml --list | jq '.role_webserver.hosts // [] | length' | \
  xargs -I{} echo "対象ホスト数: {}"

ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file "${VAULT_PASSWORD_FILE}" \
  --diff \
  "${PLAYBOOK}"

echo "=== 完了 ==="
