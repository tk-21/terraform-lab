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

# Terraform destroy 前に、ALB などの依存を生みやすい k8s リソースを先に削除する。
destroy-prep:
	./scripts/destroy_prep.sh

# tfvars を指定して Terraform destroy を実行する。
tf-destroy:
	cd infra && terraform destroy -var-file=envs/dev.tfvars -auto-approve

# Knowledge Base の再取り込みジョブを開始する。
kb-ingest:
	./scripts/kb_ingest.sh
