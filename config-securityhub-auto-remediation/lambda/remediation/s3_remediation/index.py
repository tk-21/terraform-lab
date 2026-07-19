"""
S3バケット自動修復Lambda
対応するConfig Rules:
  - csar-s3-bucket-public-read-prohibited            → Block Public Access を有効化
  - csar-s3-bucket-server-side-encryption-enabled    → AES256 SSE を設定

トリガー:
  - Config Rules Compliance Change (自動)
  - Security Hub Findings - Custom Action (手動)
"""
import json
import os
import sys

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

# Lambda Layer (/opt/python) 経由でインポート
from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-remediation-s3")
tracer = Tracer(service="csar-remediation-s3")
metrics = Metrics(namespace="CSAR", service="s3-remediation")

s3_client = boto3.client("s3", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))


def detect_trigger_source(event: dict) -> str:
    """イベントのトリガー元を判定する"""
    detail_type = event.get("detail-type", "")
    if detail_type == "Config Rules Compliance Change":
        return "CONFIG_RULE"
    elif detail_type == "Security Hub Findings - Custom Action":
        return "SECURITY_HUB_CUSTOM_ACTION"
    else:
        raise ValueError(f"未知のトリガー種別: {detail_type}")


def extract_from_config(event: dict) -> tuple[str, str]:
    """Config Ruleイベントからバケット名とルール名を抽出する"""
    detail = event["detail"]
    return detail["resourceId"], detail["configRuleName"]


def extract_from_custom_action(event: dict) -> tuple[str, str]:
    """Security Hub Custom Actionイベントからバケット名とルール名を抽出する"""
    finding = event["detail"]["findings"][0]
    # Security HubのResourceIdはARN形式: arn:aws:s3:::bucket-name
    resource_arn = finding["Resources"][0]["Id"]
    bucket_name = resource_arn.split(":::")[-1]
    rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")
    return bucket_name, rule_name


def remediate_public_access_block(bucket_name: str) -> str:
    """S3バケットのBlock Public Accessを全て有効化する"""
    s3_client.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    return "Block Public Access 有効化 (BlockPublicAcls/IgnorePublicAcls/BlockPublicPolicy/RestrictPublicBuckets=true)"


def remediate_sse(bucket_name: str) -> str:
    """S3バケットにAES256 SSEを設定する"""
    s3_client.put_bucket_encryption(
        Bucket=bucket_name,
        ServerSideEncryptionConfiguration={
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256",
                    },
                    # S3 Bucket Keyでリクエストコストを削減
                    "BucketKeyEnabled": True,
                }
            ]
        },
    )
    return "SSE-S3 (AES256) 暗号化設定 (BucketKeyEnabled=true)"


@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """S3修復Lambdaメインハンドラ"""
    logger.info("S3修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        trigger_source = detect_trigger_source(event)

        if trigger_source == "CONFIG_RULE":
            bucket_name, rule_name = extract_from_config(event)
        else:
            bucket_name, rule_name = extract_from_custom_action(event)

        logger.info("修復対象", extra={
            "bucket_name": bucket_name,
            "rule_name": rule_name,
            "trigger": trigger_source,
        })

        # ルール名に応じた修復アクション実行
        # Custom Actionの場合は両方実行 (どの違反かが特定できないため)
        actions = []
        if "public-read-prohibited" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            actions.append(remediate_public_access_block(bucket_name))

        if "server-side-encryption" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            actions.append(remediate_sse(bucket_name))

        remediation_action = " / ".join(actions) if actions else "対象ルールなし"

        record_remediation(
            remediation_id=remediation_id,
            resource_type="S3",
            resource_id=bucket_name,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=remediation_action,
            status="SUCCESS",
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        notify_remediation_result(
            resource_type="S3バケット",
            resource_id=bucket_name,
            rule_name=rule_name,
            remediation_action=remediation_action,
            status="SUCCESS",
            remediation_id=remediation_id,
        )

        metrics.add_metric(name="RemediationSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="S3")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": "SUCCESS"}

    except Exception as e:
        logger.exception("S3修復エラー", extra={"error": str(e)})
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)

        record_remediation(
            remediation_id=remediation_id,
            resource_type="S3",
            resource_id=event.get("detail", {}).get("resourceId", "UNKNOWN"),
            rule_name=event.get("detail", {}).get("configRuleName", "UNKNOWN"),
            violation_detail=event.get("detail", {}),
            remediation_action="修復失敗",
            status="FAILED",
            trigger_source=event.get("detail-type", "UNKNOWN"),
            aws_account_id=aws_account_id,
            extra={"error": str(e)},
        )

        # raiseしてLambdaリトライ→DLQ転送を発動させる
        raise
