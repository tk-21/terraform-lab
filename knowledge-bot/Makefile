# よく使うインフラ・デプロイ操作を短いコマンドで呼べるようにまとめる。
REGION ?= ap-northeast-1

# Terraform 初期化。
tf-init:
	cd infra && terraform init

# Terraform をそのまま apply する。
tf-apply:
	cd infra && terraform apply -auto-approve

# 主要な Terraform outputs を確認する。
tf-output:
	cd infra && terraform output

# app イメージをビルドして ECR に push する。
build-push:
	./scripts/build_push_ecr.sh

# 現在の k8s マニフェストを EKS に適用する。
deploy:
	./scripts/deploy_k8s.sh

# Knowledge Base の再取り込みジョブを開始する。
kb-ingest:
	./scripts/kb_ingest.sh
