#!/usr/bin/env bash
set -euo pipefail

# infra ディレクトリで Terraform の初期化と apply を一気に行う。
cd infra
terraform init
terraform apply -auto-approve
