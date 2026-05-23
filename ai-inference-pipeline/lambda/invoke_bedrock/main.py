"""
Bedrock推論Lambda
Step Functionsから呼び出され、ECS前処理済みデータに対してClaude Haikuで推論を行う。
結果はDynamoDBに保存する。
"""
import os
import json
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
