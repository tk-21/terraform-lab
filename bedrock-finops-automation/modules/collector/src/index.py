"""
コストデータ収集 Lambda

概要:
    Cost Explorer API で当月・前月のコストデータを収集し、
    S3 に JSON として保存、DynamoDB にメタ情報を記録する。

注意:
    Cost Explorer のエンドポイントは us-east-1 固定のため、
    boto3 クライアント生成時に region_name='us-east-1' を指定する。

Step Functions 連携:
    この Lambda の返り値がそのまま次のステート（anomaly-detector）の
    入力 (event) になる。Step Functions の payload 上限は 256KB のため、
    大きな生データは S3 に保存し、S3 キーのみを渡す設計にしている。
"""

import json
import logging
import os
import time
from datetime import date, datetime, timezone

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

# 環境変数（Terraform の aws_lambda_function.environment で設定）
REPORT_BUCKET_NAME = os.environ["REPORT_BUCKET_NAME"]
DYNAMODB_TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
ENVIRONMENT = os.environ.get("ENVIRONMENT", "dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "bedrock-finops-automation")


# ============================================================
# Secrets Manager 参照パターン
# （chatwork-notifier など他の Lambda でも同様に使用する共通パターン）
# ============================================================

def get_secret(secret_name: str) -> dict:
    """
    Secrets Manager からシークレットを取得する。

    シークレット命名規則: "{project_name}/{key}"
    例: "bedrock-finops-automation/chatwork-api-token"

    Args:
        secret_name: Secrets Manager のシークレット名（フルパス）

    Returns:
        シークレットの JSON をパースした dict

    Raises:
        ClientError: シークレットが存在しない or 権限不足の場合
    """
    client = boto3.client("secretsmanager")
    try:
        response = client.get_secret_value(SecretId=secret_name)
        if "SecretString" in response:
            return json.loads(response["SecretString"])
        # バイナリシークレットの場合（通常は使用しない）
        return {}
    except Exception as e:
        logger.error(f"Failed to retrieve secret '{secret_name}': {e}")
        raise


# ============================================================
# ユーティリティ関数
# ============================================================

def get_month_boundaries(target_date: date) -> tuple[str, str, str, str]:
    """
    指定日が属する月と前月の開始日・終了日を返す。

    標準ライブラリのみ使用（python-dateutil 等の外部依存なし）。

    Returns:
        (prev_month_start, current_month_start, next_month_start) を
        "YYYY-MM-DD" 形式で返す。
        Cost Explorer の TimePeriod は [Start, End) の半開区間。
    """
    # 当月初日
    current_start = target_date.replace(day=1)

    # 前月初日
    if current_start.month == 1:
        prev_start = current_start.replace(year=current_start.year - 1, month=12)
    else:
        prev_start = current_start.replace(month=current_start.month - 1)

    # 翌月初日（当月の終端として使用）
    if current_start.month == 12:
        next_start = current_start.replace(year=current_start.year + 1, month=1)
    else:
        next_start = current_start.replace(month=current_start.month + 1)

    return (
        prev_start.strftime("%Y-%m-%d"),
        current_start.strftime("%Y-%m-%d"),
        next_start.strftime("%Y-%m-%d"),
    )


def get_cost_and_usage(start_date: str, end_date: str) -> dict:
    """
    Cost Explorer API でサービス別コストデータを取得する。

    Args:
        start_date: 期間開始日 "YYYY-MM-DD"（含む）
        end_date:   期間終了日 "YYYY-MM-DD"（含まない・半開区間）

    Returns:
        GetCostAndUsage のレスポンス dict
    """
    # Cost Explorer のエンドポイントは us-east-1 固定（グローバルサービス）
    ce = boto3.client("ce", region_name="us-east-1")

    response = ce.get_cost_and_usage(
        TimePeriod={"Start": start_date, "End": end_date},
        Granularity="MONTHLY",
        # サービス別コスト内訳を取得（上位10件は Python 側でソートする）
        GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        Metrics=["UnblendedCost"],
    )
    logger.info(f"Fetched cost data: {start_date} → {end_date}")
    return response


def calc_total_cost(cost_response: dict) -> float:
    """Cost Explorer レスポンスから合計コスト（USD）を算出する。"""
    total = 0.0
    for result in cost_response.get("ResultsByTime", []):
        for group in result.get("Groups", []):
            amount = group["Metrics"]["UnblendedCost"]["Amount"]
            total += float(amount)
    return round(total, 4)


def build_service_summary(cost_response: dict) -> list[dict]:
    """
    サービス別コストを降順にソートして返す（上位10件まで）。

    Returns:
        [{"service": "Amazon EC2", "cost": 12.34}, ...]
    """
    service_costs: dict[str, float] = {}
    for result in cost_response.get("ResultsByTime", []):
        for group in result.get("Groups", []):
            service = group["Keys"][0]
            amount = float(group["Metrics"]["UnblendedCost"]["Amount"])
            service_costs[service] = service_costs.get(service, 0.0) + amount

    sorted_services = sorted(service_costs.items(), key=lambda x: x[1], reverse=True)
    return [
        {"service": svc, "cost": round(cost, 4)}
        for svc, cost in sorted_services[:10]
    ]


def save_to_s3(data: dict, s3_key: str) -> None:
    """コストデータを S3 に JSON 形式で保存する。"""
    s3 = boto3.client("s3")
    s3.put_object(
        Bucket=REPORT_BUCKET_NAME,
        Key=s3_key,
        Body=json.dumps(data, ensure_ascii=False, indent=2),
        ContentType="application/json",
    )
    logger.info(f"Saved to s3://{REPORT_BUCKET_NAME}/{s3_key}")


def save_history_to_dynamodb(
    report_id: str,
    report_date: str,
    status: str,
    metadata: dict,
) -> None:
    """レポートのメタ情報を DynamoDB に記録する。"""
    dynamodb = boto3.resource("dynamodb")
    table = dynamodb.Table(DYNAMODB_TABLE_NAME)

    # TTL: 1年後（Unix timestamp）
    expire_at = int(time.time()) + 365 * 24 * 60 * 60

    table.put_item(
        Item={
            "report_id": report_id,
            "report_date": report_date,
            "status": status,
            "metadata": json.dumps(metadata),
            "created_at": datetime.now(timezone.utc).isoformat(),
            "expire_at": expire_at,
        }
    )
    logger.info(f"Saved history: report_id={report_id}, status={status}")


# ============================================================
# Lambda ハンドラ
# ============================================================

def handler(event: dict, context) -> dict:
    """
    Lambda エントリポイント。

    Step Functions から呼び出される（月次: EventBridge → Step Functions → Lambda）。
    この関数の返り値が anomaly-detector Lambda の event として渡される。

    event パラメータ（任意）:
        target_year_month (str): 収集対象月 "YYYY-MM"（省略時は前月）
    """
    logger.info(f"Event: {json.dumps(event)}")

    # ── 対象月の決定 ──────────────────────────────────────────
    today = date.today()

    if "target_year_month" in event:
        # 手動実行・テスト用: "2025-01" 形式で月を指定可能
        ym = event["target_year_month"]
        year, month = map(int, ym.split("-"))
        target_date = date(year, month, 1)
    else:
        # デフォルト: 前月（毎月1日に前月分を集計する想定）
        first_of_this_month = today.replace(day=1)
        if first_of_this_month.month == 1:
            target_date = first_of_this_month.replace(
                year=first_of_this_month.year - 1, month=12
            )
        else:
            target_date = first_of_this_month.replace(
                month=first_of_this_month.month - 1
            )

    prev_start, current_start, next_start = get_month_boundaries(target_date)
    report_date = target_date.strftime("%Y-%m")
    report_id = f"finops-{target_date.strftime('%Y%m')}-{context.aws_request_id[:8]}"

    logger.info(
        f"Collecting: report_id={report_id}, "
        f"current=[{current_start},{next_start}), "
        f"prev=[{prev_start},{current_start})"
    )

    # ── Cost Explorer からデータ取得 ───────────────────────────
    current_cost_raw = get_cost_and_usage(current_start, next_start)
    prev_cost_raw = get_cost_and_usage(prev_start, current_start)

    # ── 集計 ──────────────────────────────────────────────────
    current_total = calc_total_cost(current_cost_raw)
    prev_total = calc_total_cost(prev_cost_raw)
    current_services = build_service_summary(current_cost_raw)
    prev_services = build_service_summary(prev_cost_raw)

    # ── S3 に生データを保存（Step Functions の 256KB 制限を回避）─
    s3_key_current = f"raw/{report_date}/current_month.json"
    s3_key_prev = f"raw/{report_date}/prev_month.json"
    save_to_s3(current_cost_raw, s3_key_current)
    save_to_s3(prev_cost_raw, s3_key_prev)

    # ── DynamoDB に履歴登録 ───────────────────────────────────
    save_history_to_dynamodb(
        report_id=report_id,
        report_date=report_date,
        status="collected",
        metadata={
            "current_total_cost": current_total,
            "prev_total_cost": prev_total,
            "s3_key_current": s3_key_current,
            "s3_key_prev": s3_key_prev,
        },
    )

    # ── 返り値（anomaly-detector への入力）────────────────────
    # 生データは S3 キー経由で渡し、サマリーのみ直接渡す
    result = {
        "report_id": report_id,
        "report_date": report_date,
        "current_month": {
            "start": current_start,
            "end": next_start,
            "total_cost": current_total,
            "top_services": current_services,
            "s3_key": s3_key_current,
        },
        "prev_month": {
            "start": prev_start,
            "end": current_start,
            "total_cost": prev_total,
            "top_services": prev_services,
            "s3_key": s3_key_prev,
        },
    }

    logger.info(
        f"Collection complete: current={current_total:.4f} USD, "
        f"prev={prev_total:.4f} USD"
    )
    return result
