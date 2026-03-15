#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TF_DIR="$ROOT_DIR/terraform/envs/dev"
INV_DIR="$ROOT_DIR/ansible/inventories/dev"

cd "$TF_DIR"

SERVER_PUBLIC_IP="$(terraform output -raw zabbix_server_public_ip)"
TARGET_PUBLIC_IP="$(terraform output -raw target_public_ip)"

SERVER_PRIVATE_IP="$(terraform output -raw zabbix_server_private_ip)"
TARGET_PRIVATE_IP="$(terraform output -raw target_private_ip)"

OUT_FILE="$INV_DIR/hosts.yml"
KEY_FILE="$ROOT_DIR/terraform/envs/dev/.ssh/zabbix_lab_key"

mkdir -p "$INV_DIR"

{
  printf "%s\n" "all:"
  printf "%s\n" "  vars:"
  printf "%s\n" "    ansible_user: ec2-user"
  printf "%s\n" "    ansible_ssh_private_key_file: ${KEY_FILE}"
  printf "%s\n" "    ansible_ssh_common_args: \"-o StrictHostKeyChecking=no\""
  printf "%s\n" "  children:"
  printf "%s\n" "    zabbix_server:"
  printf "%s\n" "      hosts:"
  printf "%s\n" "        zabbix-server:"
  printf "%s\n" "          ansible_host: ${SERVER_PUBLIC_IP}"
  printf "%s\n" "          private_ip: ${SERVER_PRIVATE_IP}"
  printf "%s\n" "    targets:"
  printf "%s\n" "      hosts:"
  printf "%s\n" "        target-01:"
  printf "%s\n" "          ansible_host: ${TARGET_PUBLIC_IP}"
  printf "%s\n" "          private_ip: ${TARGET_PRIVATE_IP}"
} > "$OUT_FILE"

echo "generated: $OUT_FILE"
echo "server public :  $SERVER_PUBLIC_IP"
echo "server private:  $SERVER_PRIVATE_IP"
echo "target public :  $TARGET_PUBLIC_IP"
echo "target private:  $TARGET_PRIVATE_IP"
