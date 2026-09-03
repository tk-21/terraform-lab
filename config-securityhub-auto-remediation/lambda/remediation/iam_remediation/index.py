"""
IAMユーザー自動修復Lambda
対応するConfig Rules:
  - csar-iam-user-mfa-enabled      → コンソールアクセス無効化 (LoginProfile削除)
  - csar-iam-user-no-policies-check → 直接アタッチポリシーを監査ログに記録して手動対応

設計意図:
  - MFA未設定ユーザーのコンソールアクセスを無効化する (ログインプロファイル削除)
  - ポリシーの直接アタッチはインプレース修復せず通知のみ
    (どのポリシーをどのグループに移すかは人間が判断すべきため)
"""
import json
import os

import boto3
from botocore.exceptions import ClientError
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from audit_logger import generate_remediation_id, record_remediation

logger = Logger(service="csar-remediation-iam")
tracer = Tracer(service="csar-remediation-iam")
metrics = Metrics(namespace="CSAR", service="iam-remediation")

iam_client = boto3.client("iam", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))


def check_user_has_mfa(username: str) -> bool:
    """ユーザーがMFAデバイスを持っているか確認する"""
    resp = iam_client.list_mfa_devices(UserName=username)
    return len(resp["MFADevices"]) > 0


def disable_console_access(username: str) -> str:
    """
    IAMユーザーのコンソールアクセスを無効化する
    LoginProfileを削除することでパスワードログイン不可になる
    """
    try:
        iam_client.delete_login_profile(UserName=username)
        return "コンソールアクセス無効化 (LoginProfile削除)"
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            # すでにLoginProfileがない場合 (プログラムアクセス専用ユーザー)
            return "LoginProfile未存在のためスキップ (プログラムアクセス専用ユーザー)"
        raise


def remediate_mfa_not_enabled(username: str) -> tuple[str, str]:
    """MFA未設定ユーザーの修復を実行する"""
    has_mfa = check_user_has_mfa(username)

    if has_mfa:
        # MFAデバイスはあるが未有効化の状態 (稀なケース)
        return "MFAデバイス登録済みだが未有効化: Config Rule再評価が必要", "MANUAL_REQUIRED"

    action = disable_console_access(username)
    return action, "SUCCESS"


def remediate_inline_policy(username: str) -> tuple[str, str]:
    """直接アタッチポリシーの修復 (インプレース修復不可のため手動対応として記録)"""
    resp = iam_client.list_attached_user_policies(UserName=username)
    policies = [p["PolicyName"] for p in resp["AttachedPolicies"]]

    if policies:
        action = f"直接アタッチポリシーの手動移行が必要: {', '.join(policies)}"
    else:
        action = "直接アタッチポリシーなし (Config Rule再評価が必要)"

    return action, "MANUAL_REQUIRED"


@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """IAM修復Lambdaメインハンドラ"""
    logger.info("IAM修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        detail_type = event.get("detail-type", "")
        trigger_source = (
            "CONFIG_RULE" if detail_type == "Config Rules Compliance Change"
            else "SECURITY_HUB_CUSTOM_ACTION"
        )

        if trigger_source == "CONFIG_RULE":
            username = event["detail"]["resourceId"]
            rule_name = event["detail"]["configRuleName"]
        else:
            finding = event["detail"]["findings"][0]
            # IAMユーザーARN: arn:aws:iam::123456789012:user/username
            username = finding["Resources"][0]["Id"].split("/")[-1]
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象IAMユーザー", extra={"username": username, "rule_name": rule_name})

        if "mfa-enabled" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            action, status = remediate_mfa_not_enabled(username)
        else:
            action, status = remediate_inline_policy(username)

        record_remediation(
            remediation_id=remediation_id,
            resource_type="IAM",
            resource_id=username,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=action,
            status=status,
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        metric_name = "RemediationSuccess" if status == "SUCCESS" else "RemediationManualRequired"
        metrics.add_metric(name=metric_name, unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="IAM")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": status}

    except Exception as e:
        logger.exception("IAM修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
