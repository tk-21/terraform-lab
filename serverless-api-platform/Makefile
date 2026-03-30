# serverless-api-platform Makefile
# 使用方法: make <target> ENV=dev
#
# 前提条件:
#   - terraform ~> 1.7 がインストールされていること
#   - AWS CLI が設定されていること（または環境変数 AWS_PROFILE が設定）
#   - python3 / pip がインストールされていること（テスト用）

ENV ?= dev
TF_DIR := terraform/environments/$(ENV)

.PHONY: init plan apply destroy fmt test lint deploy bootstrap help

# デフォルトターゲット
help:
	@echo "使用可能なターゲット:"
	@echo "  bootstrap  - Terraformバックエンド（S3+DynamoDB）を作成"
	@echo "  init       - terraform init を実行"
	@echo "  plan       - terraform plan を実行"
	@echo "  apply      - terraform apply を実行"
	@echo "  destroy    - terraform destroy を実行（注意: 全リソース削除）"
	@echo "  fmt        - terraform fmt で全ファイルをフォーマット"
	@echo "  lint       - tflint + checkov でコード品質チェック"
	@echo "  test       - Python ユニットテストを実行"
	@echo "  deploy     - Lambda 関数をデプロイ（apply 後に実行）"
	@echo ""
	@echo "ENV のデフォルト値: dev"
	@echo "例: make plan ENV=prod"

# Terraformバックエンドのブートストラップ
# 初回のみ実行。S3バケット・DynamoDBテーブルを作成する。
bootstrap:
	@echo ">> Terraformバックエンドをブートストラップしています..."
	chmod +x scripts/bootstrap.sh
	./scripts/bootstrap.sh

# terraform init
# バックエンド初期化。bootstrap 完了後に実行する。
init:
	@echo ">> terraform init (ENV=$(ENV))..."
	cd $(TF_DIR) && terraform init

# terraform plan
# 変更差分の確認。apply 前に必ず実行する。
plan:
	@echo ">> terraform plan (ENV=$(ENV))..."
	cd $(TF_DIR) && terraform plan -out=tfplan

# terraform apply
# リソースの作成・更新。plan で生成した tfplan を使用する。
apply:
	@echo ">> terraform apply (ENV=$(ENV))..."
	cd $(TF_DIR) && terraform apply tfplan

# terraform destroy
# 全リソースを削除。本番環境では絶対に実行しないこと。
destroy:
	@echo ">> [WARNING] terraform destroy (ENV=$(ENV))..."
	@read -p "本当に全リソースを削除しますか？ (yes/no): " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		cd $(TF_DIR) && terraform destroy; \
	else \
		echo "キャンセルしました。"; \
	fi

# terraform fmt
# HCLファイルを再帰的にフォーマット。PR前に実行すること。
fmt:
	@echo ">> terraform fmt..."
	terraform fmt -recursive terraform/

# tflint + checkov によるコード品質チェック
# CI/CDパイプラインでも同じコマンドを使用している。
lint:
	@echo ">> tflint..."
	cd $(TF_DIR) && tflint --init && tflint
	@echo ">> checkov..."
	checkov -d terraform/ --quiet

# Python ユニットテスト
# pytest を使用。カバレッジレポートも生成する。
test:
	@echo ">> Python ユニットテスト..."
	pip install -q pytest pytest-cov boto3 moto pydantic aws-lambda-powertools
	pytest tests/unit/ -v --cov=src --cov-report=term-missing

# Lambda 関数のデプロイ
# terraform apply 後に Lambda のコードのみを更新する場合に使用。
# 通常は terraform apply 経由でデプロイするが、
# コードのみの変更は直接更新の方が高速。
deploy:
	@echo ">> Lambda 関数をデプロイしています (ENV=$(ENV))..."
	@for func in list_items get_item create_item update_item delete_item stream_processor; do \
		echo "  Deploying $$func..."; \
		cd src/$$func && pip install -q -r requirements.txt -t . && \
		zip -q -r ../../dist/$$func.zip . && cd ../..; \
		aws lambda update-function-code \
			--function-name sap-$(ENV)-$$(echo $$func | tr '_' '-') \
			--zip-file fileb://dist/$$func.zip \
			--architectures arm64 \
			--no-cli-pager; \
	done
	@echo ">> デプロイ完了"
