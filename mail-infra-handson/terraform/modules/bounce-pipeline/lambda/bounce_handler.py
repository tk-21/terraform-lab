"""
バウンス・苦情ハンドラー Lambda関数

役割:
- SNSからバウンス/苦情イベントを受け取る
- DynamoDBのサプレッションリストに記録する
- 同じアドレスへの重複送信を防ぐ

設計原則:
- Lambda Powertools でログ・トレース
- 冪等性を保証（同じイベントを複数回処理しても結果が変わらない）
- ハードバウンス: TTLなし（永続的に送信停止）
- ソフトバウンス: TTL 30日（一時的エラーは再挑戦を許容）
- 苦情: TTLなし（永続的に送信停止）
"""

import json
import os
import time
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="bounce-handler")
tracer = Tracer(service="bounce-handler")

dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE_NAME"])

# ソフトバウンスのTTL: 30日後に自動削除（一時的障害への配慮）
SOFT_BOUNCE_TTL_SECONDS = 30 * 24 * 60 * 60


@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """SNSからバウンス/苦情イベントを受け取りDynamoDBに記録する"""

    processed = 0
    errors = 0

    for record in event.get("Records", []):
        try:
            _process_sns_record(record)
            processed += 1
        except Exception:
            logger.exception("レコード処理中にエラーが発生", extra={"record_id": record.get("Sns", {}).get("MessageId")})
            errors += 1
            # 部分的な失敗はSNSのリトライに委ねるため例外を再送出する
            raise

    logger.info("処理完了", extra={"processed": processed, "errors": errors})
    return {"statusCode": 200, "processed": processed}


def _process_sns_record(record: dict) -> None:
    """SNSレコードをパースして通知タイプに応じた処理に振り分ける"""

    # SNSメッセージはJSON文字列として格納されているためパースが必要
    sns_body = record.get("Sns", {})
    message_id = sns_body.get("MessageId", "unknown")
    raw_message = sns_body.get("Message", "{}")

    try:
        ses_notification = json.loads(raw_message)
    except json.JSONDecodeError:
        logger.error("SNSメッセージのJSONパースに失敗", extra={"message_id": message_id})
        raise

    notification_type = ses_notification.get("notificationType")
    logger.info("SES通知を受信", extra={"type": notification_type, "message_id": message_id})

    if notification_type == "Bounce":
        _handle_bounce(ses_notification)
    elif notification_type == "Complaint":
        _handle_complaint(ses_notification)
    else:
        # Delivery通知など処理不要なイベントは警告のみ
        logger.warning("処理対象外の通知タイプ", extra={"type": notification_type})


@tracer.capture_method
def _handle_bounce(notification: dict) -> None:
    """バウンスイベントを処理しサプレッションリストに記録する"""

    bounce = notification.get("bounce", {})
    bounce_type = bounce.get("bounceType", "Undetermined")
    bounce_subtype = bounce.get("bounceSubType", "Undetermined")

    # ハードバウンス（Permanent）: 宛先不明など永続的エラー → 永続的に送信停止
    # ソフトバウンス（Transient）: メールボックス満杯など一時的エラー → 30日で解除
    is_permanent = bounce_type == "Permanent"
    expires_at = None if is_permanent else int(time.time()) + SOFT_BOUNCE_TTL_SECONDS

    logger.info(
        "バウンス処理",
        extra={
            "bounce_type": bounce_type,
            "bounce_subtype": bounce_subtype,
            "is_permanent": is_permanent,
            "recipient_count": len(bounce.get("bouncedRecipients", [])),
        },
    )

    for recipient in bounce.get("bouncedRecipients", []):
        email = recipient.get("emailAddress", "")
        if not email:
            logger.warning("バウンス通知にメールアドレスが含まれていない", extra={"recipient": recipient})
            continue

        _put_suppression_record(
            email=email,
            reason="bounce",
            metadata={
                "bounce_type": bounce_type,
                "bounce_subtype": bounce_subtype,
                "diagnostic_code": recipient.get("diagnosticCode", ""),
                "action": recipient.get("action", ""),
            },
            expires_at=expires_at,
        )


@tracer.capture_method
def _handle_complaint(notification: dict) -> None:
    """苦情（スパム報告）イベントを処理し永続的にサプレッションリストに記録する"""

    complaint = notification.get("complaint", {})
    feedback_type = complaint.get("complaintFeedbackType", "unknown")
    arrival_date = complaint.get("arrivalDate", "")

    logger.info(
        "苦情処理",
        extra={
            "feedback_type": feedback_type,
            "arrival_date": arrival_date,
            "recipient_count": len(complaint.get("complainedRecipients", [])),
        },
    )

    for recipient in complaint.get("complainedRecipients", []):
        email = recipient.get("emailAddress", "")
        if not email:
            logger.warning("苦情通知にメールアドレスが含まれていない", extra={"recipient": recipient})
            continue

        # 苦情は永続的にサプレッション（TTLなし）
        # 苦情率 > 0.1% でSESアカウントが停止されるため絶対に再送しない
        _put_suppression_record(
            email=email,
            reason="complaint",
            metadata={
                "feedback_type": feedback_type,
                "arrival_date": arrival_date,
            },
            expires_at=None,
        )


@tracer.capture_method
def _put_suppression_record(
    email: str,
    reason: str,
    metadata: dict[str, Any],
    expires_at: int | None,
) -> None:
    """DynamoDBにサプレッションレコードを書き込む

    冪等性の考え方:
    同じメールアドレス + reason の組み合わせで複数回呼ばれても
    DynamoDB PutItem は最後の書き込みが有効になる（最終状態が常に正しい）
    ハードバウンスは recorded_at を更新するが suppression 自体は変わらない
    """

    item: dict[str, Any] = {
        "email": email,
        "reason": reason,
        "recorded_at": int(time.time()),
        **{k: v for k, v in metadata.items() if v},  # 空文字列は保存しない
    }

    if expires_at is not None:
        item["expires_at"] = expires_at

    table.put_item(Item=item)

    logger.info(
        "サプレッションリストに記録",
        extra={
            "email": email,
            "reason": reason,
            "is_permanent": expires_at is None,
            "expires_at": expires_at,
        },
    )
