"""
AI レポート生成 Lambda

概要:
    anomaly-detector の出力を受け取り、Amazon Bedrock（Claude 3 Haiku）を使って
    月次コストの AI 所見・改善提案を生成する。

    コスト最適化のため、モデルは Haiku 固定。
    プロンプトは簡潔にまとめ、不要な tokens を消費しない設計にする。
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REPORT_BUCKET_NAME = os.environ["REPORT_BUCKET_NAME"]
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-finops-automation")
# Terraform 変数で上書き可能（デフォルト: Haiku）
BEDROCK_MODEL_ID = os.environ.get(
    "BEDROCK_MODEL_ID", "anthropic.claude-3-haiku-20240307-v1:0"
)


# ============================================================
# プロンプト生成
# ============================================================

def build_prompt(event: dict) -> str:
    """
    コストデータ・異常検知結果からプロンプトを組み立てる。

    tokens を節約するため、数値データのみを簡潔に渡す。
    サービス名の重複や冗長な説明は省く。
    """
    report_date = event["report_date"]
    current = event["current_month"]
    prev = event["prev_month"]
    anomalies = event.get("anomalies", [])

    current_total = current["total_cost"]
    prev_total = prev["total_cost"]

    # 前月比計算
    if prev_total > 0.01:
        change_pct = ((current_total - prev_total) / prev_total) * 100
        change_str = f"{change_pct:+.1f}%"
    else:
        change_str = "（前月データなし）"

    # サービス別上位5件（プロンプト圧縮のため10件→5件）
    top_services = current.get("top_services", [])[:5]
    services_text = "\n".join(
        [f"  - {s['service']}: ${s['cost']:.2f}" for s in top_services]
    )

    # 異常検知結果
    if anomalies:
        anomaly_text = "\n".join(
            [f"  - [{a['severity']}] {a['description']}" for a in anomalies]
        )
    else:
        anomaly_text = "  異常なし"

    prompt = f"""あなたは AWS コスト最適化の専門家です。
以下の月次コストデータを分析し、簡潔な所見と改善提案を日本語で作成してください。

## 対象月: {report_date}

### コスト概要
- 当月合計: ${current_total:.2f}
- 前月合計: ${prev_total:.2f}
- 前月比: {change_str}

### サービス別コスト（上位5件）
{services_text}

### 異常検知結果
{anomaly_text}

## 出力形式（JSON）
以下の JSON 形式で出力してください。余分な説明文は不要です。

{{
  "summary": "全体的な所見を2〜3文で",
  "highlights": ["注目ポイント1", "注目ポイント2"],
  "recommendations": ["改善提案1", "改善提案2", "改善提案3"],
  "risk_level": "LOW | MEDIUM | HIGH"
}}"""

    return prompt


# ============================================================
# Bedrock 呼び出し
# ============================================================

def invoke_bedrock(prompt: str) -> dict:
    """
    Bedrock（Claude 3 Haiku）を呼び出して AI 所見を生成する。

    Messages API 形式（anthropic_version: bedrock-2023-05-31）を使用。
    max_tokens は 1024 に制限してコストを抑える。

    Returns:
        Claude が生成した JSON をパースした dict
    """
    # bedrock-runtime は ap-northeast-1 で呼び出し可能
    client = boto3.client("bedrock-runtime", region_name="ap-northeast-1")

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 1024,
        "temperature": 0.3,  # 低めに設定してコスト分析の一貫性を保つ
        "messages": [
            {
                "role": "user",
                "content": prompt,
            }
        ],
    }

    logger.info(f"Invoking Bedrock model: {BEDROCK_MODEL_ID}")
    response = client.invoke_model(
        modelId=BEDROCK_MODEL_ID,
        body=json.dumps(body),
        contentType="application/json",
        accept="application/json",
    )

    response_body = json.loads(response["body"].read())
    raw_text = response_body["content"][0]["text"]

    # 使用 tokens をログ記録（コスト監視用）
    usage = response_body.get("usage", {})
    logger.info(
        f"Bedrock usage: input_tokens={usage.get('input_tokens')}, "
        f"output_tokens={usage.get('output_tokens')}"
    )

    # Claude の出力から JSON を抽出（コードブロックに囲まれている場合も対応）
    text = raw_text.strip()
    if "```json" in text:
        text = text.split("```json")[1].split("```")[0].strip()
    elif "```" in text:
        text = text.split("```")[1].split("```")[0].strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError:
        # パース失敗時はフォールバック（ワークフローを止めない）
        logger.warning("Failed to parse Bedrock response as JSON, using raw text")
        return {
            "summary": raw_text,
            "highlights": [],
            "recommendations": [],
            "risk_level": "UNKNOWN",
        }


# ============================================================
# S3 / DynamoDB 操作
# ============================================================

def save_ai_report_to_s3(
    report_id: str, report_date: str, ai_result: dict, prompt: str
) -> str:
    """AI レポートを S3 に保存し、S3 キーを返す。"""
    s3 = boto3.client("s3")
    s3_key = f"ai-report/{report_date}/analysis.json"

    payload = {
        "report_id": report_id,
        "report_date": report_date,
        "model_id": BEDROCK_MODEL_ID,
        "ai_analysis": ai_result,
        "prompt_used": prompt,
        "generated_at": datetime.now(timezone.utc).isoformat(),
    }

    s3.put_object(
        Bucket=REPORT_BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(payload, ensure_ascii=False, indent=2),
        ContentType="application/json",
    )
    logger.info(f"Saved AI report to s3://{REPORT_BUCKET_NAME}/{s3_key}")
    return s3_key


def update_dynamodb_status(
    report_id: str, report_date: str, risk_level: str
) -> None:
    """DynamoDB のレポートレコードに AI 解析結果を追記する。"""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    table.update_item(
        Key={"report_id": report_id, "report_date": report_date},
        UpdateExpression=(
            "SET #s = :status, ai_risk_level = :risk, updated_at = :ts"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "ai_analyzed",
            ":risk": risk_level,
            ":ts": datetime.now(timezone.utc).isoformat(),
        },
    )


# ============================================================
# Lambda ハンドラ
# ============================================================

def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。

    Args:
        event: anomaly-detector Lambda の返り値

    Returns:
        event に ai_report を追加した dict（html-formatter への入力）
    """
    logger.info(f"Starting AI report generation for: {event.get('report_id')}")

    report_id = event["report_id"]
    report_date = event["report_date"]

    # ── プロンプト生成 ─────────────────────────────────────
    prompt = build_prompt(event)

    # ── Bedrock 呼び出し ──────────────────────────────────
    ai_result = invoke_bedrock(prompt)
    risk_level = ai_result.get("risk_level", "UNKNOWN")
    logger.info(f"AI analysis complete: risk_level={risk_level}")

    # ── 結果保存 ──────────────────────────────────────────
    ai_s3_key = save_ai_report_to_s3(report_id, report_date, ai_result, prompt)
    update_dynamodb_status(report_id, report_date, risk_level)

    # ── 返り値（html-formatter への入力）─────────────────
    return {
        **event,
        "ai_report": {
            "summary": ai_result.get("summary", ""),
            "highlights": ai_result.get("highlights", []),
            "recommendations": ai_result.get("recommendations", []),
            "risk_level": risk_level,
            "s3_key": ai_s3_key,
        },
    }
