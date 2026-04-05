# serverless-api-platform Makefile
# 使用方法: make <target> ENV=dev ACCOUNT_ID=123456789012
#
# 前提条件:
#   - terraform ~> 1.7 がインストールされていること
#   - AWS CLI が設定されていること（または環境変数 AWS_PROFILE が設定）
#   - python3 / pip がインストールされていること（テスト・ビルド用）
#   - zip コマンドがインストールされていること（deploy ターゲット用）

ENV        ?= dev
PROJECT    ?= sap
ACCOUNT_ID ?= $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
TF_DIR     := terraform/environments/$(ENV)
DIST_DIR   := dist
BUILD_DIR  := build

# デプロイ対象の Lambda 関数リスト（src/ 配下のディレクトリ名）
LAMBDA_FUNCS := list_items get_item create_item update_item delete_item stream_processor

.PHONY: init plan apply destroy fmt test test-unit test-integration lint build deploy bootstrap help clean

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
	@echo "  test-unit  - Python ユニットテスト（moto モック・カバレッジ 80%+ 目標）"
	@echo "  test-int   - Integration テスト（dev 環境の実 AWS リソースを使用）"
	@echo "  test       - test-unit のエイリアス"
	@echo "  build      - Lambda 関数の zip を dist/ に作成"
	@echo "  deploy     - Lambda 関数をビルドして S3 経由でデプロイ（apply 後に実行）"
	@echo "  clean      - ビルド成果物（dist/ build/）を削除"
	@echo ""
	@echo "ENV のデフォルト値: dev"
	@echo "例: make plan ENV=prod ACCOUNT_ID=123456789012"

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

# Python ユニットテスト（moto でモック・外部 AWS 通信なし）
# カバレッジ目標: 80% 以上
test-unit:
	@echo ">> Python ユニットテスト..."
	pip install -q pytest pytest-cov "boto3>=1.34" "moto[dynamodb]>=4.0" "pydantic>=2.0" "aws-lambda-powertools>=2.0"
	PYTHONPATH=src pytest tests/unit/ -v \
		--cov=src \
		--cov-report=term-missing \
		--cov-fail-under=80

# Integration テスト（実際の dev 環境 AWS リソースを使用）
# 実行前に以下の環境変数を設定すること:
#   export API_ENDPOINT=$(cd terraform/environments/dev && terraform output -raw api_endpoint)
#   export COGNITO_USER_POOL_ID=$(cd terraform/environments/dev && terraform output -raw cognito_user_pool_id)
#   export COGNITO_CLIENT_ID=$(cd terraform/environments/dev && terraform output -raw cognito_client_id)
test-integration:
	@echo ">> Integration テスト（dev 環境）..."
	pip install -q pytest "boto3>=1.34" requests
	pytest tests/integration/ -v -s -p no:randomly

# test: ユニットテストのエイリアス（後方互換）
test: test-unit

# ============================================================
# ビルド: Lambda 関数の zip を dist/ に作成する
# ============================================================
# 各関数のソースと shared モジュール・依存ライブラリを zip 化する。
# CI/CD パイプラインの deploy-lambda ジョブと同一のビルド手順を実行する。
build:
	@echo ">> Lambda 関数をビルドしています..."
	@mkdir -p $(DIST_DIR)
	@for func in $(LAMBDA_FUNCS); do \
		echo "  Building $$func..."; \
		BUILD_PATH=$(BUILD_DIR)/$$func; \
		rm -rf $$BUILD_PATH && mkdir -p $$BUILD_PATH; \
		cp -r src/$$func/. $$BUILD_PATH/; \
		cp -r src/shared $$BUILD_PATH/shared; \
		if [ -f src/$$func/requirements.txt ]; then \
			pip install -q -r src/$$func/requirements.txt -t $$BUILD_PATH; \
		fi; \
		cd $$BUILD_PATH && zip -qr ../../$(DIST_DIR)/$$func.zip . && cd ../..; \
		echo "    -> $(DIST_DIR)/$$func.zip ($$(du -sh $(DIST_DIR)/$$func.zip | cut -f1))"; \
	done
	@echo ">> ビルド完了"

# ============================================================
# デプロイ: S3 経由で Lambda を更新する（ローカルから手動デプロイする場合）
# ============================================================
# build ターゲットで作成した zip を S3 にアップロードし、
# aws lambda update-function-code で関数コードを更新する。
# 更新完了を wait で確認してから次の関数に進む。
#
# 前提: terraform apply 完了後に実行すること。
# 使用例: make deploy ENV=dev ACCOUNT_ID=123456789012
deploy: build
	@if [ -z "$(ACCOUNT_ID)" ]; then \
		echo "ERROR: ACCOUNT_ID が設定されていません。make deploy ACCOUNT_ID=123456789012"; \
		exit 1; \
	fi
	@echo ">> Lambda 関数をデプロイしています (ENV=$(ENV), ACCOUNT_ID=$(ACCOUNT_ID))..."
	@BUCKET="$(PROJECT)-$(ENV)-lambda-deployment-$(ACCOUNT_ID)"; \
	for func in $(LAMBDA_FUNCS); do \
		FUNC_NAME="$(PROJECT)-$(ENV)-$$(echo $$func | tr '_' '-')"; \
		S3_KEY="lambda/$$(echo $$func | tr '_' '-')/manual-$$(date +%Y%m%dT%H%M%S).zip"; \
		echo "  [$$FUNC_NAME]"; \
		echo "    Uploading to s3://$$BUCKET/$$S3_KEY ..."; \
		aws s3 cp "$(DIST_DIR)/$$func.zip" "s3://$$BUCKET/$$S3_KEY" --no-progress; \
		echo "    Updating Lambda code..."; \
		aws lambda update-function-code \
			--function-name "$$FUNC_NAME" \
			--s3-bucket "$$BUCKET" \
			--s3-key "$$S3_KEY" \
			--architectures arm64 \
			--no-cli-pager > /dev/null; \
		echo "    Waiting for update to complete..."; \
		aws lambda wait function-updated --function-name "$$FUNC_NAME"; \
		echo "    Done."; \
	done
	@echo ">> デプロイ完了"

# ============================================================
# クリーン: ビルド成果物を削除する
# ============================================================
clean:
	@echo ">> ビルド成果物を削除しています..."
	@rm -rf $(DIST_DIR) $(BUILD_DIR)
	@echo ">> クリーン完了"
