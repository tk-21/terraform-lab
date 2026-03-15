SHELL := /bin/bash

ROOT_DIR := $(shell pwd)
TF_DIR   := $(ROOT_DIR)/terraform/envs/dev
ANS_DIR  := $(ROOT_DIR)/ansible

REGION ?= ap-northeast-1
HOST   ?= web01
EXTRA  ?=

.PHONY: fmt tf-init validate plan apply output inv ping diff run up destroy clean

fmt:
	terraform -chdir=$(TF_DIR) fmt -recursive

tf-init:
	terraform -chdir=$(TF_DIR) init

validate:
	terraform -chdir=$(TF_DIR) validate

plan:
	terraform -chdir=$(TF_DIR) plan

apply:
	terraform -chdir=$(TF_DIR) apply

output:
	terraform -chdir=$(TF_DIR) output

inv:
	REGION=$(REGION) HOST_ALIAS=$(HOST) TF_DIR=$(TF_DIR) bash $(ROOT_DIR)/scripts/gen_inventory.sh

# SSM接続の疎通は ping が通ればOK（SSM agent / IAM / ネットワーク確認）
ping:
	cd $(ANS_DIR) && ansible -i inventories/dev/hosts.yml all -m ping

diff:
	cd $(ANS_DIR) && ansible-playbook -i inventories/dev/hosts.yml playbooks/site.yml --check --diff $(EXTRA)

run:
	cd $(ANS_DIR) && ansible-playbook -i inventories/dev/hosts.yml playbooks/site.yml $(EXTRA)

up: fmt tf-init validate apply inv ping diff run
	@echo ""
	@echo "Done: terraform apply -> inventory -> ansible ping -> diff -> run"

destroy:
	terraform -chdir=$(TF_DIR) destroy

clean:
	rm -f $(ANS_DIR)/inventories/dev/hosts.yml
	@echo "Removed generated inventory"
