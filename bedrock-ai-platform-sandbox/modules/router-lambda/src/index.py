"""
Intelligent Router Lambda
複雑度を判定してBedrock モデル（Haiku/Sonnet）を動的に切り替える。
Week4 の API Gateway と接続し、マルチテナントのトークン上限を強制する。
"""

import json
import os
import re
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Key

# ----------------------------------------------------------------
# 環境変数（Terraform で設定）
# ----------------------------------------------------------------
TENANT_TABLE    = os.environ["TENANT_TABLE"]
USAGE_TABLE     = os.environ["USAGE_TABLE"]
GUARDRAIL_ID    = os.environ["GUARDRAIL_ID"]
GUARDRAIL_VER   = os.environ["GUARDRAIL_VERSION"]
HAIKU_MODEL_ID  = os.environ["HAIKU_MODEL_ID"]
SONNET_MODEL_ID = os.environ["SONNET_MODEL_ID"]

# ----------------------------------------------------------------
# AWS クライアント
# ----------------------------------------------------------------
bedrock    = boto3.client("bedrock-runtime")
dynamodb   = boto3.resource("dynamodb")
tenant_tbl = dynamodb.Table(TENANT_TABLE)
usage_tbl  = dynamodb.Table(USAGE_TABLE)

# ----------------------------------------------------------------
# 複雑度判定: 以下のいずれかに該当すれば Sonnet へルーティング
#   1. プロンプトが 1000 文字超
#   2. 複雑系キーワードを含む
# ----------------------------------------------------------------
_COMPLEX_RE = re.compile(
    r"\b(analyz|analys|compar|explain|implement|design|architect|"
    r"debug|optim|refactor|summariz|summaris|translat|evaluat|"
    r"review|generate code|write code|create a|step.by.step)\w*\b",
    re.IGNORECASE,
)


# ================================================================
# ハンドラ
# ================================================================
def lambda_handler(event: dict, context) -> dict:
    try:
        # API Gateway プロキシ統合と直接呼び出しの両方に対応（Week4 以降）
        body = _parse_body(event)
        tenant_id = _extract_tenant_id(event, body)
        prompt    = body.get("prompt", "").strip()

        if not prompt:
            return _error(400, "prompt is required")

        # 1. テナント設定取得
        tenant = _get_tenant(tenant_id)
        if tenant is None:
            return _error(404, f"Tenant '{tenant_id}' not found")

        # 2. 日次トークン上限チェック
        if _is_over_daily_budget(tenant_id, tenant):
            return _error(429, "Daily token budget exceeded for this tenant")

        # 3. モデル選択（複雑度ルーティング）
        model_id = _select_model(prompt, tenant)

        # 4. Bedrock 呼び出し（Guardrails 適用）
        result = _invoke_bedrock(model_id, prompt)

        # 5. 使用量記録（best-effort: エラーでもレスポンスは返す）
        try:
            _record_usage(tenant_id, model_id, result["usage"])
        except Exception as e:
            print(f"[WARN] Failed to record usage: {e}")

        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps(
                {
                    "tenant_id":  tenant_id,
                    "model_used": model_id,
                    "response":   result["content"],
                    "usage":      result["usage"],
                },
                ensure_ascii=False,
            ),
        }

    except Exception as e:
        print(f"[ERROR] Unhandled exception: {e}")
        return _error(500, "Internal server error")


# ================================================================
# ヘルパー: リクエスト解析
# ================================================================
def _parse_body(event: dict) -> dict:
    raw = event.get("body", event)
    if isinstance(raw, str):
        return json.loads(raw)
    return raw if isinstance(raw, dict) else event


def _extract_tenant_id(event: dict, body: dict) -> str:
    return (
        body.get("tenant_id")
        or (event.get("headers") or {}).get("x-tenant-id")
        or "default"
    )


# ================================================================
# ヘルパー: テナント
# ================================================================
def _get_tenant(tenant_id: str) -> dict | None:
    resp = tenant_tbl.get_item(Key={"tenant_id": tenant_id})
    return resp.get("Item")


def _is_over_daily_budget(tenant_id: str, tenant: dict) -> bool:
    daily_limit = int(tenant.get("token_limit_daily", 100_000))
    today = _today()
    resp = usage_tbl.get_item(Key={"tenant_id": tenant_id, "date": today})
    used = int((resp.get("Item") or {}).get("total_tokens", 0))
    return used >= daily_limit


# ================================================================
# ヘルパー: モデル選択
# ================================================================
def _select_model(prompt: str, tenant: dict) -> str:
    # テナントがモデルを固定している場合はそれを優先
    pinned = tenant.get("preferred_model")
    if pinned:
        return pinned

    # 複雑度判定: 長いプロンプトまたは複雑系キーワード → 複雑タスク用モデル
    if len(prompt) > 1000 or _COMPLEX_RE.search(prompt):
        return SONNET_MODEL_ID

    return HAIKU_MODEL_ID


# ================================================================
# ヘルパー: Bedrock 呼び出し
# ================================================================
def _invoke_bedrock(model_id: str, prompt: str) -> dict:
    """モデルファミリーごとに正しい Bedrock ネイティブ形式で呼び出す。"""
    if model_id.startswith("amazon.nova"):
        return _invoke_nova(model_id, prompt)

    return _invoke_anthropic(model_id, prompt)


def _invoke_nova(model_id: str, prompt: str) -> dict:
    resp = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps(
            {
                "schemaVersion": "messages-v1",
                "messages": [
                    {
                        "role": "user",
                        "content": [{"text": prompt}],
                    }
                ],
                "inferenceConfig": {"maxTokens": 2048},
            }
        ),
        guardrailIdentifier=GUARDRAIL_ID,
        guardrailVersion=GUARDRAIL_VER,
        contentType="application/json",
        accept="application/json",
    )
    body = json.loads(resp["body"].read())
    content = body["output"]["message"]["content"][0]["text"]
    usage = body.get("usage", {})
    return {
        "content": content,
        "usage": {
            "input_tokens": usage.get("inputTokens", 0),
            "output_tokens": usage.get("outputTokens", 0),
        },
    }


def _invoke_anthropic(model_id: str, prompt: str) -> dict:
    resp = bedrock.invoke_model(
        modelId=model_id,
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 2048,
                "messages": [{"role": "user", "content": prompt}],
            }
        ),
        guardrailIdentifier=GUARDRAIL_ID,
        guardrailVersion=GUARDRAIL_VER,
        contentType="application/json",
        accept="application/json",
    )
    body = json.loads(resp["body"].read())
    content = body["content"][0]["text"]
    usage   = body.get("usage", {"input_tokens": 0, "output_tokens": 0})
    return {"content": content, "usage": usage}


# ================================================================
# ヘルパー: 使用量記録
# ================================================================
def _record_usage(tenant_id: str, model_id: str, usage: dict) -> None:
    today      = _today()
    now        = datetime.now(timezone.utc).isoformat()
    expires_at = int((datetime.now(timezone.utc) + timedelta(days=90)).timestamp())

    input_t  = int(usage.get("input_tokens", 0))
    output_t = int(usage.get("output_tokens", 0))
    total_t  = input_t + output_t

    usage_tbl.update_item(
        Key={"tenant_id": tenant_id, "date": today},
        UpdateExpression=(
            "ADD total_tokens :t, input_tokens :i, output_tokens :o "
            "SET last_model = :m, last_updated = :ts, expires_at = :exp"
        ),
        ExpressionAttributeValues={
            ":t":   total_t,
            ":i":   input_t,
            ":o":   output_t,
            ":m":   model_id,
            ":ts":  now,
            ":exp": expires_at,
        },
    )


# ================================================================
# ヘルパー: ユーティリティ
# ================================================================
def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d")


def _error(status: int, message: str) -> dict:
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"error": message}),
    }
