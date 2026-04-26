"""
drift-detector Lambda ハンドラー
EventBridge → Step Functionsから呼び出され、tfstateと実環境のドリフトを検知する
"""

import json
import os
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

from drift_scanner import get_cloudformation_drifts, get_terraform_resources
from state_comparator import compare_states

logger = Logger()
tracer = Tracer()

# 環境変数から設定値を取得
MONITORED_TFSTATE_BUCKET = os.environ["MONITORED_TFSTATE_BUCKET"]
MONITORED_TFSTATE_KEY = os.environ["MONITORED_TFSTATE_KEY"]
MONITORED_CFN_STACKS = os.environ.get("MONITORED_CFN_STACKS", "")


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    Step Functionsから呼び出されるメインハンドラー。
    S3のtfstateと実環境のCloudFormationドリフトを比較し結果を返す。
    """
    # スキャン対象スタック名をカンマ区切りから取得
    stack_names = [s.strip() for s in MONITORED_CFN_STACKS.split(",") if s.strip()]
    logger.info("ドリフト検知開始", extra={"monitored_stacks": stack_names})

    # S3クライアントとCloudFormationクライアントを初期化
    s3_client = boto3.client("s3")
    cfn_client = boto3.client("cloudformation")

    # S3からtfstateを取得（エラー時はStep Functionsのリトライに委ねてraiseする）
    logger.info("tfstate取得開始", extra={"bucket": MONITORED_TFSTATE_BUCKET, "key": MONITORED_TFSTATE_KEY})
    tf_resources = get_terraform_resources(s3_client, MONITORED_TFSTATE_BUCKET, MONITORED_TFSTATE_KEY)
    logger.info("tfstate取得完了", extra={"resource_count": len(tf_resources)})

    # CloudFormation Drift Detection APIでドリフト検知
    # タイムアウトした場合はget_cloudformation_driftsが空リストを返す
    cfn_drifts = []
    for stack_name in stack_names:
        try:
            stack_drifts = get_cloudformation_drifts(cfn_client, [stack_name])
            cfn_drifts.extend(stack_drifts)
        except Exception as e:
            # 個別スタックのエラーはWARNINGログを出力してスキップ
            logger.warning("スタックのドリフト検知をスキップ", extra={"stack_name": stack_name, "error": str(e)})

    logger.info("CloudFormationドリフト検知完了", extra={"drifted_resource_count": len(cfn_drifts)})

    # tfstateと実環境を突き合わせて差分を算出
    drifts = compare_states(tf_resources, cfn_drifts)

    scan_timestamp = datetime.now(timezone.utc).isoformat()

    result = {
        "drift_detected": len(drifts) > 0,
        "drift_count": len(drifts),
        "drifts": drifts,
        "scan_timestamp": scan_timestamp,
        "monitored_stacks": stack_names,
    }

    logger.info("ドリフト検知完了", extra={"drift_detected": result["drift_detected"], "drift_count": result["drift_count"]})
    return result
