"""
異常検知 Lambda

概要:
    collector Lambda から受け取ったコストデータを分析し、
    以下の3種類の異常を検知する。

検知ルール:
    1. 前月比コスト増加
       - 増加率 > MEDIUM_THRESHOLD_PCT (デフォルト 20%): MEDIUM
       - 増加率 > HIGH_THRESHOLD_PCT   (デフォルト 50%): HIGH
    2. サービス集中度
       - 単一サービスが総コストの SERVICE_CONCENTRATION_THRESHOLD (デフォルト 60%) 超: CONCENTRATION_HIGH
    3. 新規サービス検知
       - 前月に存在しなかったサービスがコスト発生: NEW_SERVICE

Step Functions 連携:
    event: collector Lambda の返り値をそのまま受け取る
    返り値: anomalies リストを追加した dict（ai-reporter への入力）
"""

import json
import logging
import os
from datetime import datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# 環境変数
REPORT_BUCKET_NAME = os.environ["REPORT_BUCKET_NAME"]
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-finops-automation")

# 異常検知閾値（Terraform の環境変数で上書き可能）
MEDIUM_THRESHOLD_PCT = float(os.environ.get("MEDIUM_THRESHOLD_PCT", "20"))
HIGH_THRESHOLD_PCT = float(os.environ.get("HIGH_THRESHOLD_PCT", "50"))
SERVICE_CONCENTRATION_THRESHOLD = float(
    os.environ.get("SERVICE_CONCENTRATION_THRESHOLD", "60")
)


# ============================================================
# 異常検知ロジック
# ============================================================

def detect_cost_increase(
    current_total: float,
    prev_total: float,
) -> dict | None:
    """
    前月比コスト増加の異常を検知する。

    前月コストが 0 または極小（$0.01未満）の場合はスキップ
    （新規アカウント・サービス開始直後のノイズ回避）。

    Returns:
        異常が検知された場合は anomaly dict、なければ None
    """
    if prev_total < 0.01:
        logger.info("Skipping cost increase check: prev_total is too small")
        return None

    increase_pct = ((current_total - prev_total) / prev_total) * 100

    if increase_pct > HIGH_THRESHOLD_PCT:
        severity = "HIGH"
    elif increase_pct > MEDIUM_THRESHOLD_PCT:
        severity = "MEDIUM"
    else:
        return None

    return {
        "type": "COST_INCREASE",
        "severity": severity,
        "description": (
            f"前月比 {increase_pct:.1f}% のコスト増加を検知"
            f"（前月: ${prev_total:.2f} → 当月: ${current_total:.2f}）"
        ),
        "current_cost": current_total,
        "prev_cost": prev_total,
        "increase_pct": round(increase_pct, 2),
        "threshold_pct": HIGH_THRESHOLD_PCT if severity == "HIGH" else MEDIUM_THRESHOLD_PCT,
    }


def detect_service_concentration(
    current_total: float,
    current_services: list[dict],
) -> dict | None:
    """
    単一サービスへのコスト集中を検知する。

    コスト上位1サービスが全体の SERVICE_CONCENTRATION_THRESHOLD% を超える場合に検知。
    総コストが $1 未満の場合はスキップ（テスト環境ノイズ回避）。

    Returns:
        異常が検知された場合は anomaly dict、なければ None
    """
    if current_total < 1.0 or not current_services:
        return None

    top_service = current_services[0]
    concentration_pct = (top_service["cost"] / current_total) * 100

    if concentration_pct <= SERVICE_CONCENTRATION_THRESHOLD:
        return None

    return {
        "type": "SERVICE_CONCENTRATION",
        "severity": "MEDIUM",
        "description": (
            f"サービス集中度アラート: {top_service['service']} が"
            f"総コストの {concentration_pct:.1f}% を占有"
            f"（${top_service['cost']:.2f} / ${current_total:.2f}）"
        ),
        "top_service": top_service["service"],
        "top_service_cost": top_service["cost"],
        "concentration_pct": round(concentration_pct, 2),
        "threshold_pct": SERVICE_CONCENTRATION_THRESHOLD,
    }


def detect_new_services(
    current_services: list[dict],
    prev_services: list[dict],
) -> list[dict]:
    """
    前月に存在しなかった新規サービスの検知。

    小額（$0.1未満）の新規サービスは除外（トライアル・無料枠の誤検知防止）。

    Returns:
        検知された新規サービスの anomaly dict リスト
    """
    prev_service_names = {s["service"] for s in prev_services}
    anomalies = []

    for svc in current_services:
        if svc["service"] not in prev_service_names and svc["cost"] >= 0.1:
            anomalies.append({
                "type": "NEW_SERVICE",
                "severity": "LOW",
                "description": (
                    f"新規サービス検知: {svc['service']} が"
                    f"初めてコスト発生（${svc['cost']:.2f}）"
                ),
                "service": svc["service"],
                "cost": svc["cost"],
            })

    return anomalies


def run_anomaly_detection(collector_output: dict) -> list[dict]:
    """
    全異常検知ルールを実行し、検知結果を統合する。

    Args:
        collector_output: collector Lambda の返り値

    Returns:
        anomaly dict のリスト（検知なしは空リスト）
    """
    current = collector_output["current_month"]
    prev = collector_output["prev_month"]

    current_total = current["total_cost"]
    prev_total = prev["total_cost"]
    current_services = current.get("top_services", [])
    prev_services = prev.get("top_services", [])

    anomalies = []

    # ルール1: 前月比コスト増加
    cost_anomaly = detect_cost_increase(current_total, prev_total)
    if cost_anomaly:
        anomalies.append(cost_anomaly)
        logger.warning(f"ANOMALY detected: {cost_anomaly['type']} [{cost_anomaly['severity']}]")

    # ルール2: サービス集中度
    concentration_anomaly = detect_service_concentration(current_total, current_services)
    if concentration_anomaly:
        anomalies.append(concentration_anomaly)
        logger.warning(
            f"ANOMALY detected: {concentration_anomaly['type']} [{concentration_anomaly['severity']}]"
        )

    # ルール3: 新規サービス
    new_service_anomalies = detect_new_services(current_services, prev_services)
    for a in new_service_anomalies:
        anomalies.append(a)
        logger.info(f"ANOMALY detected: {a['type']} - {a['service']}")

    return anomalies


# ============================================================
# DynamoDB ステータス更新
# ============================================================

def update_dynamodb_status(
    report_id: str,
    report_date: str,
    anomaly_count: int,
    has_high_severity: bool,
) -> None:
    """DynamoDB のレポートレコードに異常検知結果を追記する。"""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    table.update_item(
        Key={"report_id": report_id, "report_date": report_date},
        UpdateExpression=(
            "SET #s = :status, anomaly_count = :count, "
            "has_high_severity = :high, updated_at = :ts"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":status": "anomaly_detected",
            ":count": anomaly_count,
            ":high": has_high_severity,
            ":ts": datetime.now(timezone.utc).isoformat(),
        },
    )


def save_anomaly_report_to_s3(
    report_id: str,
    report_date: str,
    anomalies: list[dict],
) -> str:
    """異常検知レポートを S3 に保存し、S3 キーを返す。"""
    s3 = boto3.client("s3")
    s3_key = f"anomaly/{report_date}/anomaly_report.json"

    payload = {
        "report_id": report_id,
        "report_date": report_date,
        "anomaly_count": len(anomalies),
        "anomalies": anomalies,
        "detected_at": datetime.now(timezone.utc).isoformat(),
    }

    s3.put_object(
        Bucket=REPORT_BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(payload, ensure_ascii=False, indent=2),
        ContentType="application/json",
    )
    logger.info(f"Saved anomaly report to s3://{REPORT_BUCKET_NAME}/{s3_key}")
    return s3_key


# ============================================================
# Lambda ハンドラ
# ============================================================

def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。

    Args:
        event: collector Lambda の返り値
            {
              "report_id": "finops-202501-xxxxxxxx",
              "report_date": "2025-01",
              "current_month": {"total_cost": 123.45, "top_services": [...], ...},
              "prev_month":    {"total_cost": 100.00, "top_services": [...], ...},
            }

    Returns:
        event に anomalies・anomaly_summary を追加した dict（ai-reporter への入力）
    """
    logger.info(f"Event keys: {list(event.keys())}")

    report_id = event["report_id"]
    report_date = event["report_date"]
    current_total = event["current_month"]["total_cost"]
    prev_total = event["prev_month"]["total_cost"]

    logger.info(
        f"Analyzing: report_id={report_id}, "
        f"current=${current_total:.4f}, prev=${prev_total:.4f}"
    )

    # ── 異常検知実行 ─────────────────────────────────────────
    anomalies = run_anomaly_detection(event)

    has_high_severity = any(a["severity"] == "HIGH" for a in anomalies)
    anomaly_count = len(anomalies)

    logger.info(
        f"Detection complete: {anomaly_count} anomalies found, "
        f"has_high={has_high_severity}"
    )

    # ── 結果の保存 ────────────────────────────────────────────
    anomaly_s3_key = save_anomaly_report_to_s3(report_id, report_date, anomalies)
    update_dynamodb_status(report_id, report_date, anomaly_count, has_high_severity)

    # ── 返り値（ai-reporter への入力）────────────────────────
    # collector の出力に anomaly 情報を追記して渡す
    result = {
        **event,
        "anomalies": anomalies,
        "anomaly_summary": {
            "count": anomaly_count,
            "has_high_severity": has_high_severity,
            "s3_key": anomaly_s3_key,
            "severities": list({a["severity"] for a in anomalies}),
        },
    }

    return result
