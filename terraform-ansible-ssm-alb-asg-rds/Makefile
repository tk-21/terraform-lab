SHELL := /bin/bash

TF_DIR := terraform
ANS_DIR := ansible
REGION := ap-northeast-1

.PHONY: help check check-aws check-ssm-plugin check-venv check-ansible \
        tf-init tf-fmt tf-validate tf-plan tf-apply tf-destroy tf-output \
        ping configure curl all destroy

help:
	@echo "make check         # prerequisites check (aws, session-manager-plugin, terraform, ansible)"
	@echo "make tf-init       # terraform init"
	@echo "make tf-fmt        # terraform fmt -recursive"
	@echo "make tf-validate   # terraform validate"
	@echo "make tf-plan       # terraform plan (writes tfplan)"
	@echo "make tf-apply      # terraform apply"
	@echo "make tf-destroy    # terraform destroy"
	@echo "make tf-output     # terraform output"
	@echo "make ping          # ansible ping via SSM"
	@echo "make configure     # ansible-playbook site.yml (with bucket from TF output)"
	@echo "make curl          # curl http://<public_ip>"
	@echo "make all           # check -> tf-init -> tf-fmt -> tf-validate -> tf-plan -> tf-apply -> configure -> curl"
	@echo "make destroy       # tf-destroy"

# ---------------------------
# Checks
# ---------------------------
check: check-aws check-ssm-plugin check-venv check-ansible
	@echo "✅ check: OK"

check-aws:
	@command -v aws >/dev/null || (echo "❌ aws CLI not found. Install awscli and configure credentials." && exit 1)
	@aws sts get-caller-identity >/dev/null || (echo "❌ aws sts failed. Check AWS credentials/profile." && exit 1)
	@echo "✅ aws: OK"

check-ssm-plugin:
	@command -v session-manager-plugin >/dev/null || (echo "❌ session-manager-plugin not found. Install it (required for SSM)." && exit 1)
	@session-manager-plugin --version >/dev/null || (echo "❌ session-manager-plugin exists but failed to run." && exit 1)
	@echo "✅ session-manager-plugin: OK"

check-venv:
	@if [[ -z "$$VIRTUAL_ENV" ]]; then \
	  echo "❌ venv is not activated. Run: source venv/bin/activate"; \
	  exit 1; \
	fi
	@echo "✅ venv: $$VIRTUAL_ENV"

check-ansible:
	@command -v ansible >/dev/null || (echo "❌ ansible not found in PATH" && exit 1)
	@ansible --version | head -n 2
	@echo "✅ ansible: OK"

# ---------------------------
# Terraform
# ---------------------------
tf-init:
	cd $(TF_DIR) && terraform init

tf-fmt:
	cd $(TF_DIR) && terraform fmt -recursive

tf-validate:
	cd $(TF_DIR) && terraform validate

tf-plan:
	cd $(TF_DIR) && terraform plan -out tfplan
	@echo "✅ plan saved: $(TF_DIR)/tfplan"
	@cd $(TF_DIR) && terraform show -no-color tfplan | head -n 40

tf-apply:
	cd $(TF_DIR) && terraform apply -auto-approve

tf-destroy:
	cd $(TF_DIR) && terraform destroy -auto-approve

tf-output:
	cd $(TF_DIR) && terraform output

# ---------------------------
# Ansible
# ---------------------------
ping:
	cd $(ANS_DIR) && ansible all -m ping -vv

configure:
	@set -euo pipefail; \
	BUCKET="$$(cd $(TF_DIR) && terraform output -raw ssm_transfer_bucket)"; \
	DB_HOST="$$(cd $(TF_DIR) && terraform output -raw db_endpoint)"; \
	DB_NAME="$$(cd $(TF_DIR) && terraform output -raw db_name)"; \
	DB_USER="$$(cd $(TF_DIR) && terraform output -raw db_username)"; \
	echo "Using SSM transfer bucket: $$BUCKET"; \
	echo "DB host: $$DB_HOST"; \
	cd $(ANS_DIR) && ansible-playbook site.yml -vv \
	  -e "ansible_aws_ssm_region=$(REGION)" \
	  -e "ansible_aws_ssm_bucket_name=$$BUCKET" \
	  -e "db_host=$$DB_HOST" \
	  -e "db_name=$$DB_NAME" \
	  -e "db_user=$$DB_USER" \
	  -e "db_password=$$DB_PASSWORD"

# ---------------------------
# Verify
# ---------------------------
curl:
	@set -euo pipefail; \
	ALB="$$(cd $(TF_DIR) && terraform output -raw alb_dns_name)"; \
	echo "curl http://$$ALB"; \
	curl -s "http://$$ALB" | head

# ---------------------------
# One-shot
# ---------------------------
all: check tf-init tf-fmt tf-validate tf-plan tf-apply configure curl

destroy: tf-destroy
