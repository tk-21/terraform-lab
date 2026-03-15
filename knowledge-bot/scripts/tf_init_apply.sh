#!/usr/bin/env bash
set -euo pipefail
cd infra
terraform init
terraform apply -auto-approve