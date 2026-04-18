"""
analyzer-trigger Lambda ハンドラー

処理フロー:
  1. ListAnalyzers で ACCOUNT_UNUSED_ACCESS アナライザーを特定
  2. StartResourceScan でスキャン実行
  3. 最大 30 秒・5 秒間隔でスキャン完了をポーリング
  4. ListFindings で ACTIVE な未使用アクセス Findings を取得
  5. 結果を S3 に保存（analyzer-results/{YYYY}/{MM}/{DD}/findings.json）
  6. policy-advisor Lambda を非同期起動（InvocationType=Event）
"""

import json
import logging
import os
import time
from datetime import datetime, timezone, timedelta

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

JST = timezone(timedelta(hours=9))

S3_BUCKET_NAME = os.environ["S3_BUCKET_NAME"]
POLICY_ADVISOR_FUNCTION_NAME = os.environ["POLICY_ADVISOR_FUNCTION_NAME"]

SCAN_POLL_INTERVAL_SEC = 5
SCAN_POLL_MAX_SEC = 30


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント。

    EventBridge Scheduler から週次で起動される。
    スキャン実行〜S3 保存〜policy-advisor 非同期起動までの全フローを制御する。
    """
    logger.info("analyzer-trigger 開始")

    aa_client = boto3.client("accessanalyzer")
    s3_client = boto3.client("s3")
    lambda_client = boto3.client("lambda")

    analyzer_arn = get_unused_access_analyzer_arn(aa_client)
    logger.info("対象アナライザー: %s", analyzer_arn)

    run_scan_and_wait(aa_client, analyzer_arn)

    findings = list_active_findings(aa_client, analyzer_arn)
    logger.info("取得した Findings 数: %d", len(findings))

    s3_key = build_s3_key()
    payload = build_payload(analyzer_arn, findings)
    save_to_s3(s3_client, s3_key, payload)
    logger.info("S3 保存完了: s3://%s/%s", S3_BUCKET_NAME, s3_key)

    invoke_policy_advisor(lambda_client, s3_key)
    logger.info("policy-advisor 非同期起動完了")

    return {
        "statusCode": 200,
        "analyzer_arn": analyzer_arn,
        "findings_count": len(findings),
        "s3_key": s3_key,
    }


def get_unused_access_analyzer_arn(client) -> str:
    """
    ACCOUNT_UNUSED_ACCESS タイプのアナライザー ARN を返す。

    IAM アクション: access-analyzer:ListAnalyzers

    Raises:
        RuntimeError: 対象アナライザーが存在しない場合
    """
    # IAM アクション: access-analyzer:ListAnalyzers
    paginator = client.get_paginator("list_analyzers")
    for page in paginator.paginate(type="ACCOUNT_UNUSED_ACCESS"):
        for analyzer in page.get("analyzers", []):
            if analyzer["status"] == "ACTIVE":
                return analyzer["arn"]

    raise RuntimeError(
        "ACCOUNT_UNUSED_ACCESS タイプの ACTIVE なアナライザーが見つかりません。"
        "Access Analyzer コンソールでアナライザーを作成してください。"
    )


def run_scan_and_wait(client, analyzer_arn: str) -> None:
    """
    アナライザーのスキャンを開始し、完了またはタイムアウトまで待機する。

    IAM アクション: access-analyzer:StartResourceScan

    Args:
        client: boto3 accessanalyzer クライアント
        analyzer_arn: スキャン対象アナライザーの ARN
    """
    # IAM アクション: access-analyzer:StartResourceScan
    client.start_resource_scan(analyzerArn=analyzer_arn, resourceArn=analyzer_arn)
    logger.info("スキャン開始: %s", analyzer_arn)

    elapsed = 0
    while elapsed < SCAN_POLL_MAX_SEC:
        time.sleep(SCAN_POLL_INTERVAL_SEC)
        elapsed += SCAN_POLL_INTERVAL_SEC
        logger.info("スキャン待機中 (%d/%d 秒)...", elapsed, SCAN_POLL_MAX_SEC)

    logger.info("スキャン待機完了（%d 秒経過）", elapsed)


def list_active_findings(client, analyzer_arn: str) -> list[dict]:
    """
    ACTIVE ステータスの未使用アクセス Findings をすべて取得して返す。

    IAM アクション: access-analyzer:ListFindings

    対象: IAM ロール・ユーザーの未使用アクション（UNUSED_ACTION タイプ）

    Args:
        client: boto3 accessanalyzer クライアント
        analyzer_arn: 対象アナライザーの ARN

    Returns:
        Findings のリスト（finding_id / resource_arn / resource_type /
        unused_actions / last_accessed を含む辞書）
    """
    findings = []

    # IAM アクション: access-analyzer:ListFindings
    paginator = client.get_paginator("list_findings_v2")
    pages = paginator.paginate(
        analyzerArn=analyzer_arn,
        filter={
            "status": {"eq": ["ACTIVE"]},
            "findingType": {"eq": ["UnusedAction"]},
        },
    )

    for page in pages:
        for finding_summary in page.get("findings", []):
            finding = _extract_finding(finding_summary)
            if finding:
                findings.append(finding)

    return findings


def _extract_finding(finding_summary: dict) -> dict | None:
    """
    ListFindings の個別エントリーから必要フィールドを抽出して返す。

    IAM ロール・ユーザーのみ対象とし、unused_actions が空の場合はスキップする。

    Args:
        finding_summary: ListFindingsV2 のレスポンス内の finding オブジェクト

    Returns:
        抽出済み辞書。スキップ対象の場合は None。
    """
    resource_type = finding_summary.get("resourceType", "")
    if resource_type not in ("AWS::IAM::Role", "AWS::IAM::User"):
        return None

    unused_actions = _collect_unused_actions(finding_summary)
    if not unused_actions:
        return None

    last_accessed_raw = finding_summary.get("findingDetails", {}).get(
        "unusedActionDetails", {}
    ).get("lastAccessed")
    last_accessed = (
        last_accessed_raw.isoformat() if hasattr(last_accessed_raw, "isoformat")
        else str(last_accessed_raw) if last_accessed_raw
        else None
    )

    return {
        "finding_id": finding_summary["id"],
        "resource_arn": finding_summary["resource"],
        "resource_type": resource_type,
        "unused_actions": unused_actions,
        "last_accessed": last_accessed,
    }


def _collect_unused_actions(finding_summary: dict) -> list[str]:
    """
    finding_summary から未使用アクションの一覧を収集して返す。

    Args:
        finding_summary: ListFindingsV2 の finding オブジェクト

    Returns:
        未使用アクションの文字列リスト
    """
    actions = []
    details = finding_summary.get("findingDetails", {})

    # UNUSED_ACTION タイプ: findingDetails.unusedActionDetails.action
    unused_detail = details.get("unusedActionDetails", {})
    action = unused_detail.get("action")
    if action:
        actions.append(action)

    return actions


def build_s3_key() -> str:
    """
    現在の JST 日付を元に S3 保存キーを生成して返す。

    Returns:
        形式: analyzer-results/{YYYY}/{MM}/{DD}/findings.json
    """
    now_jst = datetime.now(JST)
    return f"analyzer-results/{now_jst.strftime('%Y/%m/%d')}/findings.json"


def build_payload(analyzer_arn: str, findings: list[dict]) -> dict:
    """
    S3 に保存する JSON ペイロードを構築して返す。

    Args:
        analyzer_arn: スキャンを実行したアナライザーの ARN
        findings: list_active_findings が返す Findings のリスト

    Returns:
        CLAUDE.md 仕様の JSON フォーマットに準拠した辞書
    """
    return {
        "scan_date": datetime.now(JST).isoformat(),
        "analyzer_arn": analyzer_arn,
        "findings": findings,
        "total_count": len(findings),
    }


def save_to_s3(client, s3_key: str, payload: dict) -> None:
    """
    ペイロードを JSON 形式で S3 に保存する。

    IAM アクション: s3:PutObject

    Args:
        client: boto3 s3 クライアント
        s3_key: 保存先のオブジェクトキー
        payload: 保存する辞書（JSON シリアライズ可能）
    """
    body = json.dumps(payload, ensure_ascii=False, indent=2, default=str)

    # IAM アクション: s3:PutObject
    client.put_object(
        Bucket=S3_BUCKET_NAME,
        Key=s3_key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )


def invoke_policy_advisor(client, s3_key: str) -> None:
    """
    policy-advisor Lambda を非同期（Event）で起動する。

    IAM アクション: lambda:InvokeFunction

    ペイロード: {"s3_key": "<s3_key>"}

    Args:
        client: boto3 lambda クライアント
        s3_key: 今回保存した S3 オブジェクトキー
    """
    invoke_payload = json.dumps({"s3_key": s3_key})

    # IAM アクション: lambda:InvokeFunction
    response = client.invoke(
        FunctionName=POLICY_ADVISOR_FUNCTION_NAME,
        InvocationType="Event",  # 非同期呼び出し
        Payload=invoke_payload.encode("utf-8"),
    )

    status_code = response.get("StatusCode")
    if status_code != 202:
        raise RuntimeError(
            f"policy-advisor の非同期起動に失敗しました。StatusCode={status_code}"
        )

    logger.info(
        "policy-advisor 起動: function=%s, s3_key=%s, status=%d",
        POLICY_ADVISOR_FUNCTION_NAME,
        s3_key,
        status_code,
    )
