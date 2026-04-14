"""
統合テスト用 pytest フィクスチャ。

実 AWS リソースを使用するため、以下の環境変数が必要:
  EVENTS_TABLE_NAME        : sep-dev-events
  AGGREGATIONS_TABLE_NAME  : sep-dev-aggregations
  RAW_INPUT_BUCKET         : sep-dev-raw-<account_id>
  INGEST_QUEUE_URL         : https://sqs.ap-northeast-1.amazonaws.com/<account_id>/sep-dev-ingest-queue
  INGEST_DLQ_URL           : https://sqs.ap-northeast-1.amazonaws.com/<account_id>/sep-dev-ingest-dlq
  INGESTOR_FUNCTION_NAME   : sep-dev-ingestor
  AWS_DEFAULT_REGION       : ap-northeast-1 (デフォルト)

取得方法（Terraform outputs から）:
  export EVENTS_TABLE_NAME=$(terraform -chdir=terraform/environments/dev output -raw events_table_name)
  export AGGREGATIONS_TABLE_NAME=$(terraform -chdir=terraform/environments/dev output -raw aggregations_table_name)
  export RAW_INPUT_BUCKET=$(terraform -chdir=terraform/environments/dev output -raw raw_input_bucket_name)
  export INGEST_QUEUE_URL=$(terraform -chdir=terraform/environments/dev output -raw ingest_queue_url)
  export INGEST_DLQ_URL=$(terraform -chdir=terraform/environments/dev output -raw ingest_dlq_url)
  export INGESTOR_FUNCTION_NAME=$(terraform -chdir=terraform/environments/dev output -raw ingestor_function_name)
"""
import os

import boto3
import pytest

AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "ap-northeast-1")


def _require_env(key: str) -> str:
    """必須環境変数を取得する。未設定の場合は pytest.skip でテストをスキップする。"""
    value = os.environ.get(key)
    if not value:
        pytest.skip(
            f"統合テストに必要な環境変数 {key} が設定されていません。"
            f"make test-integration を実行する前に terraform output から設定してください。"
        )
    return value


# ── セッションスコープのフィクスチャ（テストセッション全体で 1 回だけ作成）──

@pytest.fixture(scope="session")
def aws_region() -> str:
    return AWS_REGION


@pytest.fixture(scope="session")
def events_table_name() -> str:
    return _require_env("EVENTS_TABLE_NAME")


@pytest.fixture(scope="session")
def aggregations_table_name() -> str:
    return _require_env("AGGREGATIONS_TABLE_NAME")


@pytest.fixture(scope="session")
def raw_input_bucket() -> str:
    return _require_env("RAW_INPUT_BUCKET")


@pytest.fixture(scope="session")
def ingest_queue_url() -> str:
    return _require_env("INGEST_QUEUE_URL")


@pytest.fixture(scope="session")
def ingest_dlq_url() -> str:
    return _require_env("INGEST_DLQ_URL")


@pytest.fixture(scope="session")
def ingestor_function_name() -> str:
    return _require_env("INGESTOR_FUNCTION_NAME")


# ── AWS クライアントフィクスチャ ──────────────────────────────────

@pytest.fixture(scope="session")
def s3_client(aws_region):
    return boto3.client("s3", region_name=aws_region)


@pytest.fixture(scope="session")
def dynamodb_resource(aws_region):
    return boto3.resource("dynamodb", region_name=aws_region)


@pytest.fixture(scope="session")
def sqs_client(aws_region):
    return boto3.client("sqs", region_name=aws_region)


@pytest.fixture(scope="session")
def lambda_client(aws_region):
    return boto3.client("lambda", region_name=aws_region)


@pytest.fixture(scope="session")
def cloudwatch_client(aws_region):
    return boto3.client("cloudwatch", region_name=aws_region)


# ── テーブルリソースフィクスチャ ─────────────────────────────────

@pytest.fixture(scope="session")
def events_table(dynamodb_resource, events_table_name):
    return dynamodb_resource.Table(events_table_name)


@pytest.fixture(scope="session")
def aggregations_table(dynamodb_resource, aggregations_table_name):
    return dynamodb_resource.Table(aggregations_table_name)
