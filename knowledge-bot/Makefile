REGION ?= ap-northeast-1

tf-init:
	cd infra && terraform init

tf-apply:
	cd infra && terraform apply -auto-approve

tf-output:
	cd infra && terraform output

build-push:
	./scripts/build_push_ecr.sh

deploy:
	./scripts/deploy_k8s.sh

kb-ingest:
	./scripts/kb_ingest.sh