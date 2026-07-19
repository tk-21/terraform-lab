"""
監査ログ記録モジュール
DynamoDBへの修復ログ記録とS3への監査ログ保存を行う。

設計意図:
  - 修復IDで紐付け: DynamoDBとS3の両方に同じremediation_idで記録する
  - TTL付きDynamoDB: 90日後に自動削除されるためコスト管理が容易
  - S3は長期保管用 (Glacier移行あり)
  - 両方に書く理由: DynamoDBはクエリ用、S3はコンプライアンス証跡用
"""
import json
import os
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="csar-audit-logger")

# JSTタイムゾーン定義
JST = timezone(timedelta(hours=9))

# 環境変数 (Terraformで設定)
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE_NAME"]
AUDIT_BUCKET = os.environ["AUDIT_BUCKET_NAME"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

_dynamodb = None
_s3 = None


def _get_dynamodb():
    """DynamoDBクライアントのシングルトン取得 (コールドスタート最適化)"""
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.resource("dynamodb", region_name=REGION)
    return _dynamodb


def _get_s3():
    """S3クライアントのシングルトン取得"""
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=REGION)
    return _s3


def generate_remediation_id() -> str:
    """修復IDを生成する: csar-rem-YYYYMMDD-uuid8形式"""
    today = datetime.now(JST).strftime("%Y%m%d")
    short_uuid = str(uuid.uuid4())[:8]
    return f"csar-rem-{today}-{short_uuid}"


def _calc_ttl_epoch(days: int = 90) -> int:
    """DynamoDB TTL用のエポック秒を計算する (デフォルト90日後)"""
    return int((datetime.now(timezone.utc) + timedelta(days=days)).timestamp())


def record_remediation(
    remediation_id: str,
    resource_type: str,
    resource_id: str,
    rule_name: str,
    violation_detail: dict,
    remediation_action: str,
    status: str,              # "SUCCESS" / "FAILED" / "MANUAL_REQUIRED"
    trigger_source: str,      # "CONFIG_RULE" / "SECURITY_HUB_CUSTOM_ACTION"
    aws_account_id: str,
    region: str = "ap-northeast-1",
    extra: Optional[dict] = None,
) -> None:
    """修復ログをDynamoDB + S3に記録する"""
    now_jst = datetime.now(JST)
    timestamp = now_jst.isoformat()

    # DynamoDBへの記録データ
    item = {
        "remediation_id": remediation_id,
        "timestamp": timestamp,
        "resource_type": resource_type,
        "resource_id": resource_id,
        "rule_name": rule_name,
        "violation_detail": json.dumps(violation_detail, ensure_ascii=False),
        "remediation_action": remediation_action,
        "status": status,
        "trigger_source": trigger_source,
        "aws_account_id": aws_account_id,
        "region": region,
        "ttl": _calc_ttl_epoch(days=90),
    }
    if extra:
        item["extra"] = json.dumps(extra, ensure_ascii=False)

    # DynamoDB PutItem
    try:
        table = _get_dynamodb().Table(DYNAMODB_TABLE)
        table.put_item(Item=item)
        logger.info("DynamoDB修復ログ記録成功", extra={"remediation_id": remediation_id})
    except Exception as e:
        # ログ記録失敗はメイン処理を止めない (ベストエフォート)
        logger.error("DynamoDB記録エラー", extra={"error": str(e), "remediation_id": remediation_id})

    # S3へのJSONログ保存
    # キー: remediation-logs/year=YYYY/month=MM/day=DD/{remediation_id}.json
    s3_key = (
        f"remediation-logs/"
        f"year={now_jst.strftime('%Y')}/"
        f"month={now_jst.strftime('%m')}/"
        f"day={now_jst.strftime('%d')}/"
        f"{remediation_id}.json"
    )
    try:
        _get_s3().put_object(
            Bucket=AUDIT_BUCKET,
            Key=s3_key,
            Body=json.dumps(item, ensure_ascii=False, indent=2),
            ContentType="application/json",
            ServerSideEncryption="AES256",
        )
        logger.info("S3監査ログ書き込み成功", extra={"s3_key": s3_key})
    except Exception as e:
        logger.error("S3書き込みエラー", extra={"error": str(e), "s3_key": s3_key})
