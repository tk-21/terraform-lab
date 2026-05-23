# ✅Phase 2 — Docker前処理コンテナ + ECS Fargate定義

## 目標
- CSV/JSONを受け取り正規化・クレンジングするDockerコンテナを作成する
- ECRへビルド&プッシュするスクリプトを作成する
- ECS Fargate タスク定義を Terraform で管理する

---

## タスク一覧

### 2-1. Dockerfile作成

`docker/preprocessor/Dockerfile`:

```dockerfile
# ベースイメージ: arm64対応のslim版でイメージサイズを最小化
# platform指定でFargate arm64（Graviton2）との整合性を担保
FROM --platform=linux/arm64 python:3.12-slim

# セキュリティのため非rootユーザーで実行
RUN useradd -m -u 1000 appuser

WORKDIR /app

# 依存関係のインストールレイヤーをコードより先にコピー
# コードのみの変更でこのレイヤーをキャッシュ再利用するため
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

# 書き込み権限をappuserに付与
RUN chown -R appuser:appuser /app
USER appuser

# 環境変数でS3バケット名を受け取る（タスク定義から注入）
ENV INPUT_BUCKET=""
ENV OUTPUT_BUCKET=""
ENV S3_KEY=""

CMD ["python", "main.py"]
```

---

### 2-2. 前処理スクリプト作成

`docker/preprocessor/requirements.txt`:

```
boto3==1.34.0
pandas==2.2.0
```

`docker/preprocessor/main.py`:

```python
"""
前処理コンテナ: S3から入力データを取得し、正規化してS3に書き戻す
Step Functionsから環境変数でS3キー等を受け取る設計
"""
import os
import json
import logging
import boto3
import pandas as pd
from io import StringIO, BytesIO

# Lambdaと同じ形式でログ出力（CloudWatch Insights対応）
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)


def get_env(key: str) -> str:
    """必須環境変数を取得。未設定なら即座に失敗させる"""
    value = os.environ.get(key)
    if not value:
        raise ValueError(f"必須環境変数 {key} が未設定です")
    return value


def load_from_s3(s3_client, bucket: str, key: str) -> dict | list:
    """S3からJSONまたはCSVを読み込んでPythonオブジェクトに変換"""
    logger.info(f"S3から読み込み開始: s3://{bucket}/{key}")
    response = s3_client.get_object(Bucket=bucket, Key=key)
    content = response["Body"].read().decode("utf-8")

    if key.endswith(".json"):
        return json.loads(content)
    elif key.endswith(".csv"):
        df = pd.read_csv(StringIO(content))
        return df.to_dict(orient="records")
    else:
        raise ValueError(f"サポートされていないファイル形式: {key}")


def preprocess(records: list) -> dict:
    """
    データクレンジングと正規化
    - 空文字列/Noneをフィルタ
    - テキストフィールドの前後空白除去
    - Bedrock向けのプロンプト構造に整形
    """
    df = pd.DataFrame(records)

    # 全列の文字列フィールドをstrip
    str_cols = df.select_dtypes(include="object").columns
    df[str_cols] = df[str_cols].apply(lambda col: col.str.strip())

    # 空行を除去
    df.dropna(how="all", inplace=True)

    # Bedrockに渡すための構造化データに変換
    processed_records = df.to_dict(orient="records")

    return {
        "record_count": len(processed_records),
        "records": processed_records,
        "columns": list(df.columns),
    }


def save_to_s3(s3_client, bucket: str, key: str, data: dict) -> str:
    """前処理済みデータをJSONとしてS3に保存"""
    output_key = key.replace("input/", "processed/").replace(".csv", ".json")
    body = json.dumps(data, ensure_ascii=False, indent=2)

    s3_client.put_object(
        Bucket=bucket,
        Key=output_key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )
    logger.info(f"S3への保存完了: s3://{bucket}/{output_key}")
    return output_key


def main():
    input_bucket = get_env("INPUT_BUCKET")
    output_bucket = get_env("OUTPUT_BUCKET")
    s3_key = get_env("S3_KEY")
    job_id = os.environ.get("JOB_ID", "unknown")

    logger.info(f"前処理開始: job_id={job_id}, key={s3_key}")

    s3 = boto3.client("s3")

    # 入力データ取得
    raw_data = load_from_s3(s3, input_bucket, s3_key)
    if isinstance(raw_data, dict):
        records = raw_data.get("records", [raw_data])
    else:
        records = raw_data

    # 前処理実行
    processed = preprocess(records)
    processed["job_id"] = job_id
    processed["source_key"] = s3_key

    # 処理済みデータ保存
    output_key = save_to_s3(s3, output_bucket, s3_key, processed)

    logger.info(f"前処理完了: records={processed['record_count']}, output_key={output_key}")

    # Step Functionsが次のステートで使うための出力（stdout）
    print(json.dumps({
        "status": "success",
        "job_id": job_id,
        "output_key": output_key,
        "record_count": processed["record_count"],
    }))


if __name__ == "__main__":
    main()
```

---

### 2-3. ECRビルド&プッシュスクリプト作成

`scripts/build_and_push.sh`:

```bash
#!/bin/bash
# ECRへのDockerイメージビルド&プッシュスクリプト
# arm64(Graviton2)向けにビルドする点が重要（x86_64ではFargateで動作しない）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# terraform outputからECR URLを取得
ECR_URL=$(cd "$PROJECT_ROOT/terraform/environments/dev" && terraform output -raw ecr_repository_url)
AWS_REGION=${AWS_REGION:-"ap-northeast-1"}
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
IMAGE_TAG=${IMAGE_TAG:-"latest"}

echo "=== ECRログイン ==="
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

echo "=== ビルド開始 (arm64) ==="
docker buildx build \
  --platform linux/arm64 \
  --tag "$ECR_URL:$IMAGE_TAG" \
  --push \
  "$PROJECT_ROOT/docker/preprocessor"

echo "=== プッシュ完了 ==="
echo "Image: $ECR_URL:$IMAGE_TAG"
```

```bash
chmod +x scripts/build_and_push.sh
```

---

### 2-4. ECS Fargateモジュール作成

`terraform/modules/ecs/main.tf`:

```hcl
# ECS Cluster
resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    # Container Insightsを有効化してメトリクスをCloudWatchに送信
    value = "enabled"
  }
}

# Fargate SpotをデフォルトにしてECSコストを削減
# Spotは中断リスクがあるが前処理タスクは冪等設計のため問題なし
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 4
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}

# CloudWatch Logsグループ
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/aip/${var.env}/ecs/preprocessor"
  retention_in_days = 7  # ハンズオンのため短期間保持
}

# ECSタスク定義
resource "aws_ecs_task_definition" "preprocessor" {
  family                   = "${var.name_prefix}-preprocessor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  # arm64(Graviton2)はx86_64比で約20%コスト削減
  cpu                      = 256
  memory                   = 512
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  container_definitions = jsonencode([{
    name  = "preprocessor"
    image = "${var.ecr_repository_url}:latest"

    # 環境変数はStep Functionsのステートから上書きされる
    # ここではデフォルト値のみ定義
    environment = [
      { name = "INPUT_BUCKET",  value = var.input_bucket_name },
      { name = "OUTPUT_BUCKET", value = var.output_bucket_name },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.ecs.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "preprocessor"
      }
    }

    # ヘルスチェックはバッチタスクのため不要
    essential = true
  }])
}
```

`terraform/modules/ecs/variables.tf`:

```hcl
variable "name_prefix"         { type = string }
variable "env"                  { type = string }
variable "region"               { type = string }
variable "execution_role_arn"   { type = string }
variable "task_role_arn"        { type = string }
variable "ecr_repository_url"   { type = string }
variable "input_bucket_name"    { type = string }
variable "output_bucket_name"   { type = string }
```

`terraform/modules/ecs/outputs.tf`:

```hcl
output "cluster_arn"          { value = aws_ecs_cluster.main.arn }
output "cluster_name"         { value = aws_ecs_cluster.main.name }
output "task_definition_arn"  { value = aws_ecs_task_definition.preprocessor.arn }
output "task_definition_family" { value = aws_ecs_task_definition.preprocessor.family }
```

---

### 2-5. environments/dev/main.tf にECSモジュールを追加

IAMモジュールは前提となるLambda ARNが未確定のため仮ARNで定義し、phase3で更新する。

```hcl
# IAMモジュール（Lambda ARNはphase3で確定するため仮値）
module "iam" {
  source             = "../../modules/iam"
  name_prefix        = local.name_prefix
  region             = var.aws_region
  account_id         = var.aws_account_id
  input_bucket_arn   = module.s3.input_bucket_arn
  output_bucket_arn  = module.s3.output_bucket_arn
  dynamodb_table_arn = module.dynamodb.table_arn
  lambda_arns        = []  # phase3で更新
  sfn_arn            = ""  # phase4で更新
}

module "ecs" {
  source               = "../../modules/ecs"
  name_prefix          = local.name_prefix
  env                  = var.env
  region               = var.aws_region
  execution_role_arn   = module.iam.ecs_task_execution_role_arn
  task_role_arn        = module.iam.ecs_task_role_arn
  ecr_repository_url   = module.ecr.repository_url
  input_bucket_name    = module.s3.input_bucket_name
  output_bucket_name   = module.s3.output_bucket_name
}
```

---

### 2-6. Dockerビルド前提確認とプッシュ実行

```bash
# Docker buildxがarm64対応しているか確認
docker buildx ls

# なければ作成
docker buildx create --use --name arm64-builder

# ビルド&プッシュ
bash scripts/build_and_push.sh

# ECRにイメージが存在するか確認
aws ecr describe-images \
  --repository-name aip/dev/preprocessor \
  --region ap-northeast-1
```

---

### 2-7. テスト用データ準備スクリプト作成

`scripts/upload_test_data.sh`:

```bash
#!/bin/bash
# テスト用CSVをS3入力バケットにアップロード
set -euo pipefail

INPUT_BUCKET=$(cd "$(dirname "$0")/../terraform/environments/dev" && terraform output -raw input_bucket_name)

cat << 'EOF' > /tmp/test_input.csv
id,title,description,category
1,AWS Step Functions入門,サーバーレスワークフローを構築する,tech
2,Amazon Bedrockの使い方,生成AI APIを呼び出す方法,ai
3,ECS Fargateでコンテナを動かす,サーバーレスコンテナ実行環境,infra
4,,空のタイトル行（クレンジング対象）,misc
5,Terraform入門  ,前後に空白あり（正規化対象）  ,iac
EOF

aws s3 cp /tmp/test_input.csv "s3://$INPUT_BUCKET/input/test_$(date +%Y%m%d_%H%M%S).csv"
echo "アップロード完了: s3://$INPUT_BUCKET/input/"
```

```bash
chmod +x scripts/upload_test_data.sh
```

---

## terraform apply

```bash
cd terraform/environments/dev
terraform apply -auto-approve
```

---

## 完了チェックリスト

- [ ] `docker buildx build` がエラーなく完了する
- [ ] ECRにイメージが `latest` タグで存在する
- [ ] ECSクラスター `aip-dev-cluster` が作成されている
- [ ] タスク定義 `aip-dev-preprocessor` が ARM64 で定義されている
- [ ] `terraform apply` がエラーなく完了する

## 口頭説明チェックポイント
- 「なぜFargate SpotをデフォルトCapacity Providerにしているのか？」
- 「タスク定義でARMを指定する理由とコストメリットは？」
- 「ECSタスクロールとタスク実行ロールを分ける設計の意図は？」