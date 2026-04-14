# serverless-event-pipeline Makefile
# 使用方法: make <target> ENV=dev

ENV       ?= dev
TF_DIR    := terraform/environments/$(ENV)
SRC_DIR   := src
TESTS_DIR := tests
PYTEST    := $(if $(wildcard .venv/bin/pytest),.venv/bin/pytest,pytest)
UNIT_COV_TARGETS := --cov=src/aggregator --cov=src/ingestor --cov=src/shared --cov=src/transformer

.PHONY: init plan apply destroy fmt lint test bootstrap setup-python help

## インフラ操作 ##

init: ## Terraform 初期化（S3 バックエンド接続）
	@echo "==> terraform init [$(ENV)]"
	cd $(TF_DIR) && terraform init

plan: ## Terraform 実行計画の確認
	@echo "==> terraform plan [$(ENV)]"
	cd $(TF_DIR) && terraform plan -out=tfplan

apply: ## Terraform 変更の適用（plan ファイルを使用）
	@echo "==> terraform apply [$(ENV)]"
	cd $(TF_DIR) && terraform apply tfplan

destroy: ## インフラの全削除（注意: 本番環境では使用禁止）
	@echo "==> terraform destroy [$(ENV)]"
	@read -p "本当に削除しますか? [yes/no]: " confirm && [ "$$confirm" = "yes" ]
	cd $(TF_DIR) && terraform destroy

## コード品質 ##

fmt: ## Terraform ファイルのフォーマット（再帰的）
	@echo "==> terraform fmt"
	terraform fmt -recursive terraform/

lint: ## TFLint + Python flake8 による静的解析
	@echo "==> tflint"
	tflint --recursive terraform/
	@echo "==> flake8"
	flake8 $(SRC_DIR)/ --max-line-length=100 --exclude=__pycache__

## テスト ##

test-unit: ## Python ユニットテスト（moto でモック・外部依存なし）
	@echo "==> pytest unit tests"
	$(PYTEST) $(TESTS_DIR)/unit/ -v $(UNIT_COV_TARGETS) --cov-report=term-missing --cov-fail-under=80

test: test-unit ## test-unit のエイリアス（後方互換）

test-integration: ## 統合テスト（実 AWS リソースが必要・環境変数を事前に設定すること）
	@echo "==> pytest integration tests"
	@echo "==> 必要な環境変数: EVENTS_TABLE_NAME, AGGREGATIONS_TABLE_NAME, RAW_INPUT_BUCKET, INGEST_QUEUE_URL, INGEST_DLQ_URL, INGESTOR_FUNCTION_NAME"
	$(PYTEST) $(TESTS_DIR)/integration/ -v -m integration --tb=short

## セットアップ ##

setup-python: ## 開発・テスト用 Python 依存を .venv にインストールする
	@echo "==> create virtualenv"
	python3 -m venv .venv
	@echo "==> install Python dependencies"
	.venv/bin/python -m pip install --upgrade pip
	.venv/bin/python -m pip install -r requirements-dev.txt

bootstrap: ## tfstate 用 S3 バケット・DynamoDB テーブルを作成する
	@echo "==> bootstrap tfstate resources"
	scripts/bootstrap.sh

## ヘルプ ##

help: ## このヘルプを表示する
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
