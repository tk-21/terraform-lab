"""
RDS自動修復Lambda
対応するConfig Rules:
  - csar-rds-storage-encrypted              → スナップショット取得 + 手動対応通知
  - csar-rds-instance-public-access-check   → PubliclyAccessible=false に変更

設計意図:
  - RDSの暗号化はインプレースで変更不可 (DBを再作成する必要がある)
  - そのためスナップショットを取得してChatworkで通知し、手動対応を促す
  - PubliclyAccessibleはModifyDBInstanceで変更可能なため即時修復する
"""
import json
import os
from datetime import datetime, timezone, timedelta

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-remediation-rds")
tracer = Tracer(service="csar-remediation-rds")
metrics = Metrics(namespace="CSAR", service="rds-remediation")

rds_client = boto3.client("rds", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))

JST = timezone(timedelta(hours=9))


def remediate_public_access(db_identifier: str) -> tuple[str, str]:
    """RDS PubliclyAccessibleをfalseに変更する (即時修復可能)"""
    rds_client.modify_db_instance(
        DBInstanceIdentifier=db_identifier,
        PubliclyAccessible=False,
        # メンテナンスウィンドウを待たず即時適用する
        ApplyImmediately=True,
    )
    return "PubliclyAccessible=false に変更 (ApplyImmediately=true)", "SUCCESS"


def remediate_encryption_not_enabled(db_identifier: str) -> tuple[str, str]:
    """
    RDS暗号化なしの修復
    インプレース変更は不可のため、スナップショットを取得して通知する。
    移行手順:
      1. スナップショット取得 (このLambdaで実施)
      2. スナップショットから暗号化済み新DBを復元 (手動)
      3. エンドポイント切り替え後に旧DB削除 (手動)
    """
    # snapshot_idは255文字制限、英数字とハイフンのみ
    snapshot_id = f"csar-snap-{db_identifier[:20]}-{datetime.now(JST).strftime('%Y%m%d%H%M')}"
    snapshot_id = snapshot_id[:255]

    rds_client.create_db_snapshot(
        DBSnapshotIdentifier=snapshot_id,
        DBInstanceIdentifier=db_identifier,
        Tags=[
            {"Key": "CreatedBy", "Value": "csar-auto-remediation"},
            {"Key": "Reason", "Value": "encryption-not-enabled"},
        ],
    )

    action = (
        f"暗号化なしRDSのスナップショット取得: {snapshot_id} / "
        "暗号化済みDBへの移行は手動で実施 (スナップショット→暗号化復元→切り替え→旧DB削除)"
    )
    return action, "MANUAL_REQUIRED"


@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """RDS修復Lambdaメインハンドラ"""
    logger.info("RDS修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        detail_type = event.get("detail-type", "")
        trigger_source = (
            "CONFIG_RULE" if detail_type == "Config Rules Compliance Change"
            else "SECURITY_HUB_CUSTOM_ACTION"
        )

        if trigger_source == "CONFIG_RULE":
            db_identifier = event["detail"]["resourceId"]
            rule_name = event["detail"]["configRuleName"]
        else:
            finding = event["detail"]["findings"][0]
            # RDS ARN: arn:aws:rds:region:account:db:identifier
            db_identifier = finding["Resources"][0]["Id"].split(":")[-1]
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象RDS", extra={"db_identifier": db_identifier, "rule_name": rule_name})

        if "public-access-check" in rule_name:
            action, status = remediate_public_access(db_identifier)
        else:
            # storage-encrypted または Custom Action
            action, status = remediate_encryption_not_enabled(db_identifier)

        record_remediation(
            remediation_id=remediation_id,
            resource_type="RDS",
            resource_id=db_identifier,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=action,
            status=status,
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        notify_remediation_result(
            resource_type="RDS DBインスタンス",
            resource_id=db_identifier,
            rule_name=rule_name,
            remediation_action=action,
            status=status,
            remediation_id=remediation_id,
        )

        metric_name = "RemediationSuccess" if status == "SUCCESS" else "RemediationManualRequired"
        metrics.add_metric(name=metric_name, unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="RDS")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": status}

    except Exception as e:
        logger.exception("RDS修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
