"""
Cost Controller Lambda

テナントごとの日次トークン使用量を監視し、上限に近づいたら SNS でアラートを送信する。
EventBridge Scheduler により定期実行（デフォルト: 1時間ごと）。
"""

import json
import os
from datetime import datetime, timezone

import boto3

# ----------------------------------------------------------------
# 環境変数（Terraform で設定）
# ----------------------------------------------------------------
TENANT_TABLE = os.environ["TENANT_TABLE"]
USAGE_TABLE  = os.environ["USAGE_TABLE"]
ALERT_TOPIC  = os.environ["ALERT_TOPIC_ARN"]
WARN_PERCENT = int(os.environ.get("WARN_PERCENT", "80"))

# ----------------------------------------------------------------
# AWS クライアント
# ----------------------------------------------------------------
dynamodb   = boto3.resource("dynamodb")
sns        = boto3.client("sns")
tenant_tbl = dynamodb.Table(TENANT_TABLE)
usage_tbl  = dynamodb.Table(USAGE_TABLE)


# ================================================================
# ハンドラ
# ================================================================
def lambda_handler(event: dict, context) -> dict:
    today        = _today()
    alerts       = []
    tenant_count = 0

    # テナントテーブルをスキャン（ページネーション対応）
    last_key = None
    while True:
        kwargs = {"ExclusiveStartKey": last_key} if last_key else {}
        resp = tenant_tbl.scan(**kwargs)

        for tenant in resp.get("Items", []):
            tenant_count += 1
            alert = _check_tenant(tenant, today)
            if alert:
                alerts.append(alert)

        last_key = resp.get("LastEvaluatedKey")
        if not last_key:
            break

    if alerts:
        _publish_alerts(alerts)
        print(f"[INFO] Published {len(alerts)} budget alert(s) for {tenant_count} tenants checked")
    else:
        print(f"[INFO] All {tenant_count} tenants within budget")

    return {
        "statusCode":      200,
        "date":            today,
        "tenants_checked": tenant_count,
        "alerts":          alerts,
    }


# ================================================================
# ヘルパー
# ================================================================
def _check_tenant(tenant: dict, today: str) -> dict | None:
    tenant_id   = tenant["tenant_id"]
    daily_limit = int(tenant.get("token_limit_daily", 100_000))

    resp = usage_tbl.get_item(Key={"tenant_id": tenant_id, "date": today})
    used = int((resp.get("Item") or {}).get("total_tokens", 0))
    pct  = round(used / daily_limit * 100, 1) if daily_limit > 0 else 0.0

    if pct >= 100:
        status = "EXCEEDED"
    elif pct >= WARN_PERCENT:
        status = "WARNING"
    else:
        return None

    print(f"[ALERT] tenant={tenant_id} status={status} used={used}/{daily_limit} ({pct}%)")
    return {
        "tenant_id": tenant_id,
        "tier":      tenant.get("tier", "unknown"),
        "status":    status,
        "used":      used,
        "limit":     daily_limit,
        "percent":   pct,
        "date":      today,
    }


def _publish_alerts(alerts: list[dict]) -> None:
    message = {
        "source":    "bedrock-ai-platform-sandbox/cost-controller",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "alerts":    alerts,
    }
    sns.publish(
        TopicArn=ALERT_TOPIC,
        Subject=f"[Bedrock AI Platform] Budget Alert – {len(alerts)} tenant(s) affected",
        Message=json.dumps(message, ensure_ascii=False, indent=2),
    )


def _today() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d")
