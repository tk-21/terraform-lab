"""
メール受信時スパム判定Lambda

SES Receipt RuleのLambdaアクションとして呼び出される。
受信メールを解析してスパム判定を行い、結果をDynamoDBに記録する。
戻り値でSES Receipt Ruleの後続アクション続行/停止を制御する。

判定ロジック（優先順位順）:
1. SES組み込みスパム/ウイルス判定（spamVerdict / virusVerdict）
2. DMARCアライメント失敗チェック（Authentication-Results ヘッダー）
3. 送信元IPのブロックリスト確認（DynamoDBサプレッションリスト）

戻り値:
- {"disposition": "CONTINUE"}      → 次のアクション（S3保存）へ
- {"disposition": "STOP_RULE_SET"} → ルールセット全体を停止（スパムをドロップ）
"""

import json
import os
import time
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="spam-handler")
tracer = Tracer(service="spam-handler")
metrics = Metrics(namespace="MailInfraHandson")

dynamodb = boto3.resource("dynamodb")
cloudwatch = boto3.client("cloudwatch")

SPAM_LOG_TABLE_NAME = os.environ["SPAM_LOG_TABLE_NAME"]
SUPPRESSION_TABLE_NAME = os.environ.get("SUPPRESSION_TABLE_NAME", "")


def _parse_ses_event(event: dict) -> dict:
    """SESイベントから受信メールのメタデータを抽出する"""
    ses_notification = event["Records"][0]["ses"]
    mail = ses_notification["mail"]
    receipt = ses_notification["receipt"]

    return {
        "message_id": mail["messageId"],
        "timestamp": mail["timestamp"],
        "source": mail.get("source", "unknown"),
        "destination": mail.get("destination", []),
        "headers": {h["name"]: h["value"] for h in mail.get("headers", [])},
        "spam_verdict": receipt.get("spamVerdict", {}).get("status", "PROCESSING"),
        "virus_verdict": receipt.get("virusVerdict", {}).get("status", "PROCESSING"),
        "spf_verdict": receipt.get("spfVerdict", {}).get("status", "PROCESSING"),
        "dkim_verdict": receipt.get("dkimVerdict", {}).get("status", "PROCESSING"),
        "dmarc_verdict": receipt.get("dmarcVerdict", {}).get("status", "PROCESSING"),
    }


def _check_spam_verdict(mail_meta: dict) -> tuple[bool, str]:
    """SES組み込みスパム/ウイルス判定の結果を確認する"""
    if mail_meta["virus_verdict"] == "FAIL":
        metrics.add_metric(name="VirusDetected", unit=MetricUnit.Count, value=1)
        return True, "ウイルス検出（SES組み込みチェック）"

    if mail_meta["spam_verdict"] == "FAIL":
        metrics.add_metric(name="SpamDetected", unit=MetricUnit.Count, value=1)
        return True, "スパム判定（SES組み込みチェック）"

    return False, ""


def _check_dmarc(mail_meta: dict) -> tuple[bool, str]:
    """DMARCアライメント失敗を確認する。FAILは強く疑わしいためブロック対象とする"""
    if mail_meta["dmarc_verdict"] == "FAIL":
        metrics.add_metric(name="DmarcFailed", unit=MetricUnit.Count, value=1)
        return True, "DMARC検証失敗（なりすまし疑い）"
    return False, ""


def _check_suppression_list(source_email: str) -> tuple[bool, str]:
    """送信元メールアドレスがアプリレベルのサプレッションリストに存在するか確認する"""
    if not SUPPRESSION_TABLE_NAME or not source_email or source_email == "unknown":
        return False, ""

    try:
        table = dynamodb.Table(SUPPRESSION_TABLE_NAME)
        response = table.get_item(
            Key={"email": source_email, "reason": "bounce"}
        )
        if "Item" in response:
            return True, f"送信元アドレスがサプレッションリストに存在: {source_email}"
    except Exception as e:
        # サプレッションリスト確認失敗時は通過させる（フォールセーフ）
        logger.warning("サプレッションリスト確認エラー（通過扱い）", error=str(e))

    return False, ""


def _record_spam_log(
    mail_meta: dict,
    is_spam: bool,
    reason: str,
    disposition: str,
) -> None:
    """スパム判定結果をDynamoDBのスパムログテーブルに記録する"""
    try:
        table = dynamodb.Table(SPAM_LOG_TABLE_NAME)
        received_at = datetime.now(timezone.utc).isoformat()
        # 30日後に自動削除（TTL）
        expires_at = int(time.time()) + (30 * 24 * 60 * 60)

        table.put_item(
            Item={
                "message_id": mail_meta["message_id"],
                "received_at": received_at,
                "source": mail_meta["source"],
                "is_spam": is_spam,
                "reason": reason,
                "disposition": disposition,
                "verdicts": {
                    "spam": mail_meta["spam_verdict"],
                    "virus": mail_meta["virus_verdict"],
                    "spf": mail_meta["spf_verdict"],
                    "dkim": mail_meta["dkim_verdict"],
                    "dmarc": mail_meta["dmarc_verdict"],
                },
                "expires_at": expires_at,
            }
        )
    except Exception as e:
        # ログ記録失敗はクリティカルではないためwarnに留める
        logger.warning("スパムログ記録失敗", error=str(e))


@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
@metrics.log_metrics
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """
    SES Receipt Rule Lambdaアクションのエントリポイント。

    各判定ロジックを優先順位順に実行し、いずれかがTrueを返した時点で
    STOP_RULE_SETを返してルールセット全体を停止し、S3保存などの後続アクションをスキップする。
    """
    try:
        mail_meta = _parse_ses_event(event)
    except (KeyError, IndexError) as e:
        logger.error("SESイベント解析失敗", error=str(e))
        # イベント解析失敗時は安全側に倒してCONTINUE（ドロップしない）
        return {"disposition": "CONTINUE"}

    logger.info(
        "受信メール解析",
        message_id=mail_meta["message_id"],
        source=mail_meta["source"],
        spam_verdict=mail_meta["spam_verdict"],
        virus_verdict=mail_meta["virus_verdict"],
        dmarc_verdict=mail_meta["dmarc_verdict"],
    )

    # 判定ロジックを順番に実行
    checks = [
        _check_spam_verdict(mail_meta),
        _check_dmarc(mail_meta),
        _check_suppression_list(mail_meta["source"]),
    ]

    is_spam = False
    reason = "クリーン（スパム判定なし）"
    disposition = "CONTINUE"

    for check_result, check_reason in checks:
        if check_result:
            is_spam = True
            reason = check_reason
            disposition = "STOP_RULE_SET"
            break

    _record_spam_log(mail_meta, is_spam, reason, disposition)

    logger.info(
        "スパム判定結果",
        message_id=mail_meta["message_id"],
        is_spam=is_spam,
        reason=reason,
        disposition=disposition,
    )

    return {"disposition": disposition}
