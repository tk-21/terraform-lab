# ✅Phase 3 — Lambda: Bedrock推論 + Chatwork通知

## 目標
- Lambda（arm64/Python3.12）でBedrockを呼び出しDynamoDBに結果を保存する
- 別Lambdaでジョブ結果をChatworkに通知する
- Terraformでパッケージング・デプロイまで管理する

---

## タスク一覧

### 3-1. Bedrock推論Lambda作成

`lambda/invoke_bedrock/main.py`:

```python
"""
Bedrock推論Lambda
Step Functionsから呼び出され、ECS前処理済みデータに対してClaude Haikuで推論を行う。
結果はDynamoDBに保存する。
"""
import os
import json
import logging
import boto3
from datetime import datetime, timezone, timedelta
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

# Lambda Powertoolsで構造化ログ（CloudWatch Logs Insightsで検索可能にするため）
logger = Logger(service="invoke-bedrock")
tracer = Tracer()

bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")
dynamodb = boto3.resource("dynamodb")
s3 = boto3.client("s3")

TABLE_NAME = os.environ["DYNAMODB_TABLE"]
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0")
OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]


def load_processed_data(bucket: str, key: str) -> dict:
    """前処理済みデータをS3から取得"""
    response = s3.get_object(Bucket=bucket, Key=key)
    return json.loads(response["Body"].read().decode("utf-8"))


def build_prompt(data: dict) -> str:
    """
    Bedrock向けプロンプトを構築
    レコードの内容を要約・分類・インサイト抽出させる
    """
    records_text = json.dumps(data["records"], ensure_ascii=False, indent=2)
    return f"""以下のデータを分析し、JSON形式で回答してください。

データ:
{records_text}

以下の観点で分析してください:
1. summary: データ全体の要約（100文字以内）
2. key_themes: 主要なテーマやキーワード（最大5つのリスト）
3. categories: データのカテゴリ分布
4. recommendations: このデータから得られる推奨アクション（最大3つ）
5. data_quality: データ品質の評価（"high"/"medium"/"low"）

必ずJSONのみを返し、説明文や```json```ブロックは不要です。"""


def invoke_bedrock(prompt: str) -> dict:
    """
    Bedrock Claude Haikuを呼び出す
    Haikuを選択している理由: 本ユースケースでは速度とコストが最優先のため
    """
    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1000,
        "messages": [{"role": "user", "content": prompt}],
    }

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps(body),
        contentType="application/json",
        accept="application/json",
    )

    result = json.loads(response["body"].read())
    raw_text = result["content"][0]["text"]

    # Bedrockの出力をJSONとしてパース
    try:
        return json.loads(raw_text)
    except json.JSONDecodeError:
        # パース失敗時はテキストをそのまま保存（ジョブは失敗させない）
        logger.warning("Bedrockの出力がJSON形式ではありません", raw_text=raw_text[:200])
        return {"raw_response": raw_text}


def save_result(job_id: str, data: dict, inference_result: dict) -> None:
    """
    推論結果をDynamoDBに保存
    TTLは7日後に設定してストレージコストを自動削減
    """
    table = dynamodb.Table(TABLE_NAME)
    now = datetime.now(timezone(timedelta(hours=9)))  # JST
    expires_at = int((now + timedelta(days=7)).timestamp())

    table.put_item(Item={
        "job_id": job_id,
        "created_at": now.isoformat(),
        "status": "completed",
        "record_count": data.get("record_count", 0),
        "source_key": data.get("source_key", ""),
        "inference_result": inference_result,
        "model_id": MODEL_ID,
        "expires_at": expires_at,
    })


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    event形式（Step Functionsから受け取る）:
    {
      "job_id": "uuid",
      "output_key": "processed/xxx.json",
    }
    """
    logger.info("推論開始", event=event)

    job_id = event["job_id"]
    output_key = event["output_key"]

    # 前処理済みデータ取得
    processed_data = load_processed_data(OUTPUT_BUCKET, output_key)

    # Bedrockプロンプト構築・推論実行
    prompt = build_prompt(processed_data)
    inference_result = invoke_bedrock(prompt)

    logger.info("推論完了", job_id=job_id, result_keys=list(inference_result.keys()))

    # DynamoDB保存
    save_result(job_id, processed_data, inference_result)

    return {
        "status": "success",
        "job_id": job_id,
        "inference_result": inference_result,
    }
```

---

### 3-2. Chatwork通知Lambda作成

`lambda/notify_chatwork/main.py`:

```python"""
Chatwork通知Lambda
Step Functionsのパイプライン完了・失敗時に呼び出される。
成功/失敗どちらのケースも同じLambdaで処理する。
"""
import os
import json
import logging
import urllib.request
import urllib.parse
import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="notify-chatwork")

ssm = boto3.client("ssm")

ROOM_ID = os.environ["CHATWORK_ROOM_ID"]
SSM_TOKEN_PATH = os.environ["SSM_TOKEN_PATH"]


def get_chatwork_token() -> str:
    """SSM Parameter StoreからChatworkトークンを取得（SecureString）"""
    response = ssm.get_parameter(Name=SSM_TOKEN_PATH, WithDecryption=True)
    return response["Parameter"]["Value"]


def format_message(event: dict) -> str:
    """
    ジョブの結果に応じてChatworkメッセージを整形
    成功時は推論サマリーを、失敗時はエラー内容を含める
    """
    job_id = event.get("job_id", "unknown")
    status = event.get("status", "unknown")

    if status == "success":
        result = event.get("inference_result", {})
        summary = result.get("summary", "サマリーなし")
        themes = ", ".join(result.get("key_themes", []))
        quality = result.get("data_quality", "-")

        return (
            f"[info][title]✅ AI推論パイプライン完了[/title]"
            f"Job ID: {job_id}\n"
            f"データ品質: {quality}\n"
            f"サマリー: {summary}\n"
            f"主要テーマ: {themes}"
            f"[/info]"
        )
    else:
        error = event.get("error", "不明なエラー")
        return (
            f"[info][title]❌ AI推論パイプライン失敗[/title]"
            f"Job ID: {job_id}\n"
            f"エラー: {error}"
            f"[/info]"
        )


def send_chatwork_message(token: str, room_id: str, message: str) -> None:
    """Chatwork APIにPOSTリクエストを送信"""
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({"body": message}).encode("utf-8")

    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )

    with urllib.request.urlopen(req, timeout=10) as resp:
        logger.info("Chatwork送信完了", status_code=resp.status)


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("通知Lambda開始", event=event)

    token = get_chatwork_token()
    message = format_message(event)
    send_chatwork_message(token, ROOM_ID, message)

    return {"status": "notified"}
```

---

### 3-3. Lambdaモジュール作成

`terraform/modules/lambda/main.tf`:

```hcl
# Lambda用ロググループ（保持期間を短くしてコスト抑制）
resource "aws_cloudwatch_log_group" "bedrock" {
  name              = "/aws/lambda/${var.name_prefix}-invoke-bedrock"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "notify" {
  name              = "/aws/lambda/${var.name_prefix}-notify-chatwork"
  retention_in_days = 7
}

# Bedrock推論Lambdaのパッケージング
# Lambda Powertoolsはlayerで提供されているためzipには含めない
data "archive_file" "invoke_bedrock" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/invoke_bedrock"
  output_path = "${path.module}/artifacts/invoke_bedrock.zip"
}

data "archive_file" "notify_chatwork" {
  type        = "zip"
  source_dir  = "${path.root}/../../../lambda/notify_chatwork"
  output_path = "${path.module}/artifacts/notify_chatwork.zip"
}

# Lambda Powertoolsのマネージドレイヤー（arm64用）
# バージョンは定期的に更新されるため変数化
data "aws_lambda_layer_version" "powertools" {
  layer_name = "AWSLambdaPowertoolsPythonV3-python312-arm64"
}

resource "aws_lambda_function" "invoke_bedrock" {
  function_name = "${var.name_prefix}-invoke-bedrock"
  role          = var.lambda_bedrock_role_arn
  handler       = "main.handler"
  runtime       = "python3.12"

  # Graviton2でコスト最適化
  architectures = ["arm64"]
  timeout       = 120  # Bedrock推論は最大60秒程度かかる場合があるため余裕を持たせる
  memory_size   = 256

  filename         = data.archive_file.invoke_bedrock.output_path
  source_code_hash = data.archive_file.invoke_bedrock.output_base64sha256

  layers = [data.aws_lambda_layer_version.powertools.arn]

  environment {
    variables = {
      DYNAMODB_TABLE    = var.dynamodb_table_name
      BEDROCK_MODEL_ID  = "anthropic.claude-3-haiku-20240307-v1:0"
      OUTPUT_BUCKET     = var.output_bucket_name
      POWERTOOLS_SERVICE_NAME = "invoke-bedrock"
      LOG_LEVEL         = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  depends_on = [aws_cloudwatch_log_group.bedrock]
}

resource "aws_lambda_function" "notify_chatwork" {
  function_name = "${var.name_prefix}-notify-chatwork"
  role          = var.lambda_notify_role_arn
  handler       = "main.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  timeout       = 30
  memory_size   = 128  # 通知のみのため最小メモリで十分

  filename         = data.archive_file.notify_chatwork.output_path
  source_code_hash = data.archive_file.notify_chatwork.output_base64sha256

  layers = [data.aws_lambda_layer_version.powertools.arn]

  environment {
    variables = {
      CHATWORK_ROOM_ID  = var.chatwork_room_id
      SSM_TOKEN_PATH    = "/aip/${var.env}/chatwork/token"
      POWERTOOLS_SERVICE_NAME = "notify-chatwork"
      LOG_LEVEL         = "INFO"
    }
  }

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [var.lambda_security_group_id]
  }

  depends_on = [aws_cloudwatch_log_group.notify]
}

# Lambdaのセキュリティグループ
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda関数用 - VPC Endpoint経由のAWSサービス通信のみ"
  vpc_id      = var.vpc_id

  # アウトバウンドのみ（インバウンドルールなし = Step Functionsからの呼び出しはSG不要）
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS: VPC Endpoint / Chatwork API"
  }
}
```

`terraform/modules/lambda/variables.tf`:

```hcl
variable "name_prefix"              { type = string }
variable "env"                       { type = string }
variable "vpc_id"                    { type = string }
variable "private_subnet_ids"        { type = list(string) }
variable "lambda_bedrock_role_arn"   { type = string }
variable "lambda_notify_role_arn"    { type = string }
variable "dynamodb_table_name"       { type = string }
variable "output_bucket_name"        { type = string }
variable "chatwork_room_id"          { type = string }
```

`terraform/modules/lambda/outputs.tf`:

```hcl
output "invoke_bedrock_arn"    { value = aws_lambda_function.invoke_bedrock.arn }
output "notify_chatwork_arn"   { value = aws_lambda_function.notify_chatwork.arn }
output "lambda_security_group_id" { value = aws_security_group.lambda.id }
```

---

### 3-4. environments/dev にLambdaモジュール追加 + IAM更新

`terraform/environments/dev/main.tf` に追記:

```hcl
module "lambda" {
  source                  = "../../modules/lambda"
  name_prefix             = local.name_prefix
  env                     = var.env
  vpc_id                  = var.vpc_id
  private_subnet_ids      = var.private_subnet_ids
  lambda_bedrock_role_arn = module.iam.lambda_bedrock_role_arn
  lambda_notify_role_arn  = module.iam.lambda_notify_role_arn
  dynamodb_table_name     = module.dynamodb.table_name
  output_bucket_name      = module.s3.output_bucket_name
  chatwork_room_id        = var.chatwork_room_id
}
```

IAMモジュールの `lambda_arns` を確定値に更新:

```hcl
# module "iam" の lambda_arns を以下に変更
lambda_arns = [
  module.lambda.invoke_bedrock_arn,
  module.lambda.notify_chatwork_arn,
]
```

---

### 3-5. SSM Parameter Store にChatworkトークンを登録

```bash
aws ssm put-parameter \
  --name "/aip/dev/chatwork/token" \
  --value "YOUR_CHATWORK_TOKEN" \
  --type "SecureString" \
  --region ap-northeast-1
```

---

### 3-6. Apply + 単体テスト

```bash
cd terraform/environments/dev

# artifactsディレクトリを作成しておく
mkdir -p ../../modules/lambda/artifacts

terraform apply -auto-approve

# Lambda単体テスト（invoke_bedrock）
aws lambda invoke \
  --function-name aip-dev-invoke-bedrock \
  --payload '{"job_id":"test-001","output_key":"processed/test.json"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda_output.json && cat /tmp/lambda_output.json
```

---

## 完了チェックリスト

- [ ] 2つのLambda関数が `arm64` で作成されている
- [ ] `invoke_bedrock` のテスト呼び出しがDynamoDBに結果を書き込む
- [ ] DynamoDBテーブルにレコードが存在する
- [ ] SSM Parameter Storeにトークンが登録されている

## 口頭説明チェックポイント
- 「Lambda Powertoolsをlayerで使う理由は何か？」
- 「BedrockのモデルIDをHaikuに固定した設計意図は？」
- 「LambdaのIAMロールにiam:PutPolicyを付与しない理由は？」