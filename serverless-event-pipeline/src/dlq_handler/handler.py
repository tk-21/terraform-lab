"""
dlq-handler Lambda — 失敗イベント分類・再処理・dead-letter-archive

CLAUDE.md エラーハンドリング戦略の実装:
  DLQ に滞留したメッセージを以下の3カテゴリに分類して処理する。

  [一時エラー: TRANSIENT]
    原因: Throttling・タイムアウト・接続エラーなど一時的な障害
    対応: 元のキューに指数バックオフ DelaySeconds を付けて再エンキュー
    再処理後: DLQ から削除

  [恒久エラー: PERMANENT]
    原因: バリデーション失敗・スキーマ不整合など修正が必要なデータ問題
    対応: S3 dead-letter-archive に gzip 圧縮して保存
          prefix: permanent/<YYYY-MM-DD>/<message_id>.json.gz
    保存後: DLQ から削除

  [不明エラー: UNKNOWN]
    原因: 分類不能（上記のいずれのキーワードにも一致しない）
    対応: S3 dead-letter-archive に gzip 圧縮して保存
          prefix: unknown/<YYYY-MM-DD>/<message_id>.json.gz
          + SNS でアラート送信（即時確認が必要）
    保存後: DLQ から削除

トリガー:
  - EventBridge Scheduler（5 分ごとの定期実行）: 常時 DLQ を監視してドレインする
  - EventBridge ルール（CloudWatch Alarm ALARM 状態変化）: DLQ 滞留時の即時起動

MessageAttributes 分類方針（STEP 3 からの一貫性）:
  上流 Lambda（ingestor / transformer）が SQS に再エンキューする際に
  failure_reason・error_type・attempt_count 属性を付与する前提。
  属性が存在しない場合はメッセージボディのキーワードマッチングにフォールバックする。

環境変数（必須）:
  DLQ_QUEUE_MAPPING          : JSON 文字列 {"dlq_url": "source_queue_url", ...}
                                複数 DLQ をコンマ区切りでなく JSON で管理する（可読性向上）
  DEAD_LETTER_ARCHIVE_BUCKET : dead-letter-archive S3 バケット名
  ALERTS_SNS_TOPIC_ARN       : UNKNOWN エラーアラート送信先 SNS トピック ARN
"""

import gzip
import json
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Any

import boto3
from aws_lambda_powertools import Logger, Metrics, Tracer
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from shared.utils import build_tracer, get_env

# ── Powertools 初期化 ─────────────────────────────────────────
# モジュールレベルで初期化することでコールドスタート時のオーバーヘッドを一度だけ支払う。
logger = Logger()
tracer = build_tracer()
metrics = Metrics(namespace="ServerlessEventPipeline")

# ── AWS クライアント初期化 ────────────────────────────────────
# ウォームスタートで接続を再利用してレイテンシを削減する。
_sqs_client = boto3.client("sqs")
_s3_client = boto3.client("s3")
_sns_client = boto3.client("sns")
_cw_client = boto3.client("cloudwatch")

# ── 定数 ─────────────────────────────────────────────────────
# 1 回の Lambda 実行で処理する DLQ あたりの最大メッセージ数。
# Lambda タイムアウト（60 秒）内に収まるように設定する。
_MAX_MESSAGES_PER_DLQ = 100

# SQS ReceiveMessage API 1 回あたりの最大取得件数（AWS 上限）
_MAX_RECEIVE_PER_CALL = 10

# DelaySeconds の最大値: SQS の上限は 900 秒（15 分）
_MAX_DELAY_SECONDS = 900

# CloudWatch Metrics の集計期間（7 日分）
_METRICS_PERIOD_DAYS = 7


# ── 失敗分類 Enum ─────────────────────────────────────────────


class FailureCategory(Enum):
    TRANSIENT = "transient"   # 再試行可能（Throttling・タイムアウト・接続エラー）
    PERMANENT = "permanent"   # 恒久エラー（バリデーション失敗・スキーマ不整合）
    UNKNOWN   = "unknown"     # 分類不能（SNS アラート + S3 保存）


# ── 分類キーワード定義 ────────────────────────────────────────

# TRANSIENT キーワード: 一時的な障害を示すエラーメッセージのキーワード
# AWS SDK のエラーコード・メッセージで頻出するパターンを網羅する。
_TRANSIENT_KEYWORDS: tuple[str, ...] = (
    "throttl",                          # ThrottlingException, ProvisionedThroughputExceededException
    "timeout",                          # Lambda タイムアウト, SDK タイムアウト
    "timed out",                        # "connection timed out" などの接続タイムアウト
    "connection",                       # ConnectionError, connection refused
    "temporarily unavailable",          # サービス一時停止
    "too many requests",                # HTTP 429
    "rate exceeded",                    # API レート超過
    "capacity exceeded",                # DynamoDB キャパシティ超過
    "provisionedthroughputexceeded",    # DynamoDB スループット超過
    "requestexpired",                   # リクエスト有効期限切れ
    "serviceunavailable",               # HTTP 503
    "internal server error",            # HTTP 500（再試行で解消する場合がある）
    "transientfailure",                 # 明示的な一時障害フラグ
    "retriable",                        # 再試行可能フラグ
)

# PERMANENT キーワード: データ品質・スキーマ問題を示すキーワード
# 再試行しても解消しない根本的な問題を識別する。
_PERMANENT_KEYWORDS: tuple[str, ...] = (
    "validation",                       # Pydantic ValidationError, バリデーション失敗
    "schema",                           # スキーマ不整合
    "invalid",                          # 不正な値・フォーマット
    "missing field",                    # 必須フィールド欠落
    "missing required",                 # 必須項目未指定
    "parse error",                      # JSON パースエラー
    "json decode",                      # JSON デコードエラー
    "format error",                     # フォーマット不正
    "typeerror",                        # 型エラー
    "valueerror",                       # 値エラー
    "not found",                        # リソース未存在（データ不整合）
    "does not exist",                   # 存在しないリソース
    "permanent",                        # 明示的な恒久エラーフラグ
    "unrecoverable",                    # 回復不能フラグ
    "bad request",                      # HTTP 400
    "malformed",                        # 不正形式のリクエスト
)


# ── データクラス ──────────────────────────────────────────────


@dataclass
class MessageProcessingResult:
    """1 件のメッセージ処理結果"""
    message_id: str
    category: FailureCategory
    reason: str
    success: bool
    detail: str = ""


@dataclass
class DlqProcessingResult:
    """1 つの DLQ の処理結果集計"""
    dlq_url: str
    transient_count: int = 0    # 再エンキューした件数
    permanent_count: int = 0    # S3 保存した件数（恒久エラー）
    unknown_count: int = 0      # S3 保存 + SNS アラートした件数
    error_count: int = 0        # 処理自体が失敗した件数（DLQ から削除しない）
    s3_keys: list[str] = field(default_factory=list)  # アーカイブした S3 オブジェクトキー


# ── 失敗分類ロジック ──────────────────────────────────────────


@tracer.capture_method
def _classify_failure(message: dict) -> tuple[FailureCategory, str]:
    """
    SQS メッセージの失敗理由を分類する。

    分類優先順位:
      1. MessageAttributes の error_type 属性（明示的な分類が最優先）
      2. MessageAttributes の failure_reason キーワードマッチング
      3. メッセージボディのキーワードマッチング（フォールバック）
      4. UNKNOWN（分類不能）

    Args:
        message: SQS ReceiveMessage レスポンスの 1 メッセージ dict

    Returns:
        (FailureCategory, 失敗理由の文字列) のタプル
    """
    attrs = message.get("MessageAttributes", {})

    # ── Step 1: 明示的な error_type 属性による分類 ──────────────
    # 上流 Lambda が MessageAttributes に error_type を付与している場合は
    # それを最優先で使用する（曖昧なキーワードマッチより正確）。
    error_type_attr = attrs.get("error_type", {})
    if error_type_attr:
        error_type = error_type_attr.get("StringValue", "").lower().strip()
        if error_type in ("transient", "throttling", "timeout", "retriable"):
            return FailureCategory.TRANSIENT, f"explicit error_type: {error_type}"
        if error_type in ("permanent", "validation", "schema", "unrecoverable"):
            return FailureCategory.PERMANENT, f"explicit error_type: {error_type}"

    # ── Step 2: failure_reason 属性のキーワードマッチング ────────
    # 上流 Lambda が failure_reason に例外メッセージや AWS エラーコードを付与している場合。
    # TRANSIENT と PERMANENT の両方に一致する場合は TRANSIENT を優先する
    # （安全側に倒して再試行させる。永続失敗は attempt_count の上限で止まる）。
    failure_reason_attr = attrs.get("failure_reason", {})
    failure_reason = failure_reason_attr.get("StringValue", "").lower() if failure_reason_attr else ""

    if failure_reason:
        for keyword in _TRANSIENT_KEYWORDS:
            if keyword in failure_reason:
                return FailureCategory.TRANSIENT, f"failure_reason keyword '{keyword}': {failure_reason[:200]}"
        for keyword in _PERMANENT_KEYWORDS:
            if keyword in failure_reason:
                return FailureCategory.PERMANENT, f"failure_reason keyword '{keyword}': {failure_reason[:200]}"

    # ── Step 3: メッセージボディのキーワードマッチング ──────────
    # MessageAttributes に情報がない場合のフォールバック。
    # ボディに JSON が含まれていれば error / message フィールドも検索する。
    body = message.get("Body", "")
    body_lower = body.lower()

    # ボディから JSON を解析してエラーフィールドを抽出する
    body_error_text = body_lower
    try:
        body_dict = json.loads(body)
        # よくあるエラーフィールド名を結合して検索文字列を作る
        error_fields = []
        for key in ("error", "errorMessage", "error_message", "message", "detail", "reason"):
            if key in body_dict and isinstance(body_dict[key], str):
                error_fields.append(body_dict[key].lower())
        if error_fields:
            body_error_text = " ".join(error_fields) + " " + body_lower
    except (json.JSONDecodeError, TypeError):
        # JSON でない場合はそのままボディテキストを使用する
        pass

    for keyword in _TRANSIENT_KEYWORDS:
        if keyword in body_error_text:
            return FailureCategory.TRANSIENT, f"body keyword '{keyword}'"
    for keyword in _PERMANENT_KEYWORDS:
        if keyword in body_error_text:
            return FailureCategory.PERMANENT, f"body keyword '{keyword}'"

    # ── Step 4: 分類不能 → UNKNOWN ─────────────────────────────
    # どのキーワードにも一致しない場合は UNKNOWN として SNS アラートを発火する。
    # 運用者が手動でパターンを追加するためのシグナルとして機能する。
    return FailureCategory.UNKNOWN, "no matching keywords in attributes or body"


def _get_attempt_count(message: dict) -> int:
    """
    メッセージの再試行回数を取得する。

    優先順位:
      1. MessageAttributes の attempt_count（上流 Lambda が付与した試行回数）
      2. SQS システム属性の ApproximateReceiveCount（DLQ 含む累計受信回数から推定）

    Args:
        message: SQS メッセージ dict

    Returns:
        試行回数（0 以上の整数）
    """
    # 上流 Lambda が付与した明示的な attempt_count を優先する
    attrs = message.get("MessageAttributes", {})
    count_attr = attrs.get("attempt_count", {})
    if count_attr:
        try:
            return max(0, int(count_attr.get("StringValue", "0")))
        except (ValueError, TypeError):
            pass

    # フォールバック: SQS ApproximateReceiveCount から推定する
    # DLQ で受信した場合は 1 から始まるため -1 して実質の試行回数に調整する
    sys_attrs = message.get("Attributes", {})
    try:
        return max(0, int(sys_attrs.get("ApproximateReceiveCount", "1")) - 1)
    except (ValueError, TypeError):
        return 0


# ── メッセージ処理関数群 ──────────────────────────────────────


@tracer.capture_method
def _reenqueue(
    message: dict,
    source_queue_url: str,
    attempt_count: int,
) -> None:
    """
    一時エラーのメッセージを元のキューに指数バックオフで再エンキューする。

    指数バックオフ戦略:
      DelaySeconds = min(2^attempt_count × 10, 900)
      例: attempt=0 → 10s, attempt=1 → 20s, attempt=2 → 40s,
          attempt=5 → 320s, attempt=7+ → 900s（SQS 上限）

    上限設定の根拠:
      900 秒（15 分）は SQS DelaySeconds の最大値。
      試行回数が多いほど遅延を長くすることで、
      バックプレッシャーとして機能しダウンストリームへの負荷を軽減する。

    MessageAttributes の引き継ぎ:
      元のメッセージ属性をそのまま引き継ぎ、attempt_count と requeued_at を更新する。
      これにより次の DLQ 処理でも正確な試行回数が参照できる。

    Args:
        message:          SQS メッセージ dict
        source_queue_url: 再エンキュー先（元のキュー）の URL
        attempt_count:    現在の試行回数（DelaySeconds 計算に使用）
    """
    # 指数バックオフ: 2^attempt × 10 秒、上限 900 秒
    delay_seconds = min(2 ** attempt_count * 10, _MAX_DELAY_SECONDS)

    # 元の MessageAttributes を引き継ぎ、試行情報を更新する
    # ※ SQS の MessageAttributes は 10 個までという制約があるため過剰に追加しない
    updated_attrs: dict[str, Any] = {
        k: v for k, v in message.get("MessageAttributes", {}).items()
        if k not in ("attempt_count", "requeued_at")
    }
    updated_attrs["attempt_count"] = {
        "DataType": "Number",
        "StringValue": str(attempt_count + 1),
    }
    updated_attrs["requeued_at"] = {
        "DataType": "String",
        "StringValue": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    _sqs_client.send_message(
        QueueUrl=source_queue_url,
        MessageBody=message["Body"],
        DelaySeconds=delay_seconds,
        MessageAttributes=updated_attrs,
    )

    logger.info(
        "一時エラーメッセージを元キューに再エンキュー",
        extra={
            "message_id": message["MessageId"],
            "source_queue_url": source_queue_url,
            "delay_seconds": delay_seconds,
            "attempt_count": attempt_count + 1,
        },
    )


@tracer.capture_method
def _archive_to_s3(
    message: dict,
    category: FailureCategory,
    reason: str,
    bucket: str,
) -> str:
    """
    メッセージを S3 dead-letter-archive に gzip 圧縮して保存する。

    保存形式:
      - プレフィックス: <category>/<YYYY-MM-DD>/<message_id>.json.gz
      - エンコード: UTF-8 JSON → gzip 圧縮（最大 70-90% のサイズ削減）
      - ContentEncoding: "gzip" で S3 コンソールからの直接参照を可能にする

    アーカイブデータの構造:
      - message_id / receipt_handle: SQS の識別子（調査・削除に必要）
      - body: 元のメッセージ本体（再処理・デバッグに使用）
      - attributes / message_attributes: SQS の全属性情報
      - failure_category / failure_reason: 分類結果と理由
      - archived_at: アーカイブ日時（S3 ライフサイクルとは別の監査ログ）

    ライフサイクル: Terraform で 90 日後 GLACIER 移行、365 日後削除を設定する。

    Args:
        message:  SQS メッセージ dict
        category: 失敗カテゴリ（permanent / unknown）
        reason:   失敗理由の文字列
        bucket:   dead-letter-archive S3 バケット名

    Returns:
        保存先の S3 オブジェクトキー
    """
    now = datetime.now(timezone.utc)
    date_str = now.strftime("%Y-%m-%d")
    message_id = message["MessageId"]

    # プレフィックス: <category>/<date>/<message_id>.json.gz
    s3_key = f"{category.value}/{date_str}/{message_id}.json.gz"

    # アーカイブデータを構築する（調査に必要な全情報を含める）
    archive_data = {
        "message_id": message_id,
        "receipt_handle": message.get("ReceiptHandle", ""),
        "body": message.get("Body", ""),
        "attributes": message.get("Attributes", {}),
        "message_attributes": message.get("MessageAttributes", {}),
        "failure_category": category.value,
        "failure_reason": reason,
        "archived_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    # JSON → UTF-8 bytes → gzip 圧縮
    # ensure_ascii=False で日本語等のマルチバイト文字を圧縮前に保持する
    json_bytes = json.dumps(archive_data, ensure_ascii=False, default=str).encode("utf-8")
    gzip_bytes = gzip.compress(json_bytes)

    _s3_client.put_object(
        Bucket=bucket,
        Key=s3_key,
        Body=gzip_bytes,
        ContentEncoding="gzip",
        ContentType="application/json",
        # メタデータとして失敗理由を付与（S3 コンソールから内容を開かずに把握できる）
        Metadata={
            "failure-category": category.value,
            "failure-reason": reason[:256],  # S3 メタデータの最大値は 2KB（合計）
        },
    )

    logger.info(
        "メッセージを dead-letter-archive に保存",
        extra={
            "message_id": message_id,
            "s3_key": s3_key,
            "category": category.value,
            "original_size_bytes": len(json_bytes),
            "compressed_size_bytes": len(gzip_bytes),
        },
    )

    return s3_key


@tracer.capture_method
def _send_unknown_alert(
    message: dict,
    reason: str,
    s3_key: str,
    topic_arn: str,
) -> None:
    """
    UNKNOWN カテゴリのメッセージについて SNS でアラートを送信する。

    UNKNOWN エラーは分類ルールに存在しない新種のエラーである可能性が高いため、
    即座に運用者へ通知して手動調査を促す。
    アーカイブ済みの S3 キーを通知に含めることで調査の導線を提供する。

    Args:
        message:   SQS メッセージ dict
        reason:    分類不能の理由（キーワードが見つからなかった詳細）
        s3_key:    アーカイブ先 S3 オブジェクトキー
        topic_arn: アラート送信先 SNS トピック ARN
    """
    subject = f"[SEP] DLQ 分類不能メッセージを検出: {message['MessageId'][:8]}..."

    sns_message = (
        f"DLQ で分類不能なメッセージが検出されました。\n\n"
        f"  メッセージ ID : {message['MessageId']}\n"
        f"  分類理由      : {reason}\n"
        f"  S3 アーカイブ : s3://{s3_key}\n\n"
        f"  ボディ（先頭 500 文字）:\n"
        f"  {message.get('Body', '')[:500]}\n\n"
        f"  分類キーワードの追加が必要な場合は dlq_handler/handler.py の\n"
        f"  _TRANSIENT_KEYWORDS / _PERMANENT_KEYWORDS を更新してください。"
    )

    _sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject,
        Message=sns_message,
    )

    logger.warning(
        "UNKNOWN エラーのアラートを SNS に送信",
        extra={
            "message_id": message["MessageId"],
            "reason": reason,
            "s3_key": s3_key,
        },
    )


# ── CloudWatch メトリクス取得 ─────────────────────────────────


@tracer.capture_method
def _get_7day_dlq_count(dlq_name: str) -> int:
    """
    過去 7 日間の DLQ への累計転送件数を CloudWatch Metrics から取得する。

    使用するメトリクス:
      Namespace : AWS/SQS
      MetricName: NumberOfMessagesSent
      Dimension : QueueName = <dlq_name>

    NumberOfMessagesSent の意味:
      キューに追加されたメッセージ数（元の SQS キューから DLQ へ移動した件数）。
      現在の滞留件数（ApproximateNumberOfMessagesVisible）とは異なり、
      過去の累計傾向を把握するのに適している。

    Args:
        dlq_name: DLQ のキュー名（ARN / URL ではなく名前のみ）

    Returns:
        過去 7 日間の累計 DLQ 転送件数（データポイントがない場合は 0）
    """
    now = datetime.now(timezone.utc)
    start_time = now - timedelta(days=_METRICS_PERIOD_DAYS)

    response = _cw_client.get_metric_statistics(
        Namespace="AWS/SQS",
        MetricName="NumberOfMessagesSent",
        Dimensions=[{"Name": "QueueName", "Value": dlq_name}],
        StartTime=start_time,
        EndTime=now,
        # 7 日分を 1 時間粒度で取得し Sum で集計する
        # （604800 秒を Period にすると粒度が粗くて SUM が 0 になる場合がある）
        Period=3600,
        Statistics=["Sum"],
    )

    datapoints = response.get("Datapoints", [])
    if not datapoints:
        return 0

    return int(sum(dp["Sum"] for dp in datapoints))


# ── DLQ ドレイン処理 ──────────────────────────────────────────


@tracer.capture_method
def _process_single_message(
    message: dict,
    source_queue_url: str,
    archive_bucket: str,
    alerts_topic_arn: str,
) -> MessageProcessingResult:
    """
    DLQ の 1 メッセージを分類して処理する。

    処理フロー:
      1. _classify_failure でカテゴリを判定する
      2. TRANSIENT → _reenqueue で指数バックオフ再エンキュー
      3. PERMANENT → _archive_to_s3 で S3 保存
      4. UNKNOWN   → _archive_to_s3 + _send_unknown_alert

    このメソッドが例外を throw しないよう設計する（呼び出し元で DLQ 削除可否を判断するため）。
    処理失敗の場合は success=False を返し、DLQ からの削除をスキップさせる。

    Args:
        message:           SQS メッセージ dict
        source_queue_url:  TRANSIENT 時の再エンキュー先 URL
        archive_bucket:    PERMANENT/UNKNOWN 時の S3 バケット名
        alerts_topic_arn:  UNKNOWN 時の SNS アラート宛先

    Returns:
        MessageProcessingResult（success=True ならば DLQ から削除する）
    """
    message_id = message["MessageId"]
    category, reason = _classify_failure(message)

    logger.info(
        "メッセージ分類結果",
        extra={
            "message_id": message_id,
            "category": category.value,
            "reason": reason,
        },
    )

    try:
        if category == FailureCategory.TRANSIENT:
            # 一時エラー: 指数バックオフで元キューに再エンキューする
            attempt_count = _get_attempt_count(message)
            _reenqueue(message, source_queue_url, attempt_count)
            return MessageProcessingResult(
                message_id=message_id,
                category=category,
                reason=reason,
                success=True,
                detail=f"requeued to {source_queue_url}",
            )

        elif category == FailureCategory.PERMANENT:
            # 恒久エラー: S3 dead-letter-archive に保存してから DLQ を削除する
            s3_key = _archive_to_s3(message, category, reason, archive_bucket)
            return MessageProcessingResult(
                message_id=message_id,
                category=category,
                reason=reason,
                success=True,
                detail=s3_key,
            )

        else:  # UNKNOWN
            # 分類不能: S3 保存 + SNS アラートで即時通知する
            s3_key = _archive_to_s3(message, category, reason, archive_bucket)
            _send_unknown_alert(message, reason, s3_key, alerts_topic_arn)
            return MessageProcessingResult(
                message_id=message_id,
                category=category,
                reason=reason,
                success=True,
                detail=s3_key,
            )

    except Exception as e:
        # 処理自体が失敗した場合はメッセージを DLQ に残す（削除しない）。
        # 次回の dlq-handler 実行で再処理される（可視性タイムアウト後）。
        logger.error(
            "メッセージ処理中に例外が発生しました",
            extra={
                "message_id": message_id,
                "category": category.value,
                "error": str(e),
                "error_type": type(e).__name__,
            },
        )
        return MessageProcessingResult(
            message_id=message_id,
            category=category,
            reason=reason,
            success=False,
            detail=f"{type(e).__name__}: {str(e)[:200]}",
        )


@tracer.capture_method
def _drain_dlq(
    dlq_url: str,
    source_queue_url: str,
    archive_bucket: str,
    alerts_topic_arn: str,
) -> DlqProcessingResult:
    """
    1 つの DLQ を最大 _MAX_MESSAGES_PER_DLQ 件処理するまでドレインする。

    ドレイン戦略:
      1. ReceiveMessage で最大 10 件取得（ショートポーリング）
      2. 各メッセージを _process_single_message で処理
      3. success=True のメッセージのみ DLQ から削除
      4. DLQ が空（Messages が空）になるか上限件数に達したらループ終了

    DLQ のドレイン停止条件:
      - キューが空になった（Messages が空のレスポンス）
      - 処理件数が _MAX_MESSAGES_PER_DLQ に達した
        （Lambda タイムアウトを避けるための安全策）

    Args:
        dlq_url:           処理対象 DLQ の URL
        source_queue_url:  TRANSIENT メッセージの再エンキュー先
        archive_bucket:    S3 アーカイブバケット名
        alerts_topic_arn:  UNKNOWN アラート SNS トピック ARN

    Returns:
        DlqProcessingResult（カテゴリ別の処理件数）
    """
    result = DlqProcessingResult(dlq_url=dlq_url)
    processed_count = 0

    logger.info("DLQ のドレイン開始", extra={"dlq_url": dlq_url})

    while processed_count < _MAX_MESSAGES_PER_DLQ:
        # SQS ReceiveMessage: 残り処理枠と上限 10 件の小さい方を取得する
        remaining = _MAX_MESSAGES_PER_DLQ - processed_count
        max_msgs = min(_MAX_RECEIVE_PER_CALL, remaining)

        response = _sqs_client.receive_message(
            QueueUrl=dlq_url,
            MaxNumberOfMessages=max_msgs,
            # SQS の全システム属性を取得する（ApproximateReceiveCount など）
            AttributeNames=["All"],
            # 全 MessageAttributes を取得する（failure_reason・error_type など）
            MessageAttributeNames=["All"],
            # ショートポーリング（WaitTimeSeconds=0）でキューが空なら即座に空レスポンスを返す。
            # ロングポーリングは待機コストが高く、定期実行の場合は不要。
            WaitTimeSeconds=0,
        )

        messages = response.get("Messages", [])
        if not messages:
            # DLQ が空になった: ドレイン完了
            logger.info(
                "DLQ が空です。ドレイン完了",
                extra={"dlq_url": dlq_url, "processed_count": processed_count},
            )
            break

        # メッセージを順番に処理し、成功したものを DLQ から削除する
        for message in messages:
            msg_result = _process_single_message(
                message, source_queue_url, archive_bucket, alerts_topic_arn
            )
            processed_count += 1

            # 処理成功: DLQ からメッセージを削除する
            # 失敗の場合は削除せず可視性タイムアウト後に次回の dlq-handler で再処理
            if msg_result.success:
                _sqs_client.delete_message(
                    QueueUrl=dlq_url,
                    ReceiptHandle=message["ReceiptHandle"],
                )

                # カテゴリ別カウントを更新する
                if msg_result.category == FailureCategory.TRANSIENT:
                    result.transient_count += 1
                    metrics.add_metric(name="DlqTransientRequeued", unit=MetricUnit.Count, value=1)
                elif msg_result.category == FailureCategory.PERMANENT:
                    result.permanent_count += 1
                    result.s3_keys.append(msg_result.detail)
                    metrics.add_metric(name="DlqPermanentArchived", unit=MetricUnit.Count, value=1)
                else:  # UNKNOWN
                    result.unknown_count += 1
                    result.s3_keys.append(msg_result.detail)
                    metrics.add_metric(name="DlqUnknownArchived", unit=MetricUnit.Count, value=1)
            else:
                result.error_count += 1
                metrics.add_metric(name="DlqProcessingErrors", unit=MetricUnit.Count, value=1)

    logger.info(
        "DLQ ドレイン完了",
        extra={
            "dlq_url": dlq_url,
            "transient": result.transient_count,
            "permanent": result.permanent_count,
            "unknown": result.unknown_count,
            "errors": result.error_count,
        },
    )

    return result


# ── SNS サマリー送信 ──────────────────────────────────────────


def _send_summary(
    results: list[DlqProcessingResult],
    topic_arn: str,
) -> None:
    """
    全 DLQ の処理結果サマリーを SNS に送信する。

    サマリーに含める情報:
      - 再処理件数（TRANSIENT）
      - 恒久エラー件数（PERMANENT）
      - 不明件数（UNKNOWN）
      - 直近 7 日間の各 DLQ への累計転送件数（CloudWatch Metrics）
      - アーカイブした S3 キーの一覧（最大 5 件まで）

    サマリーを送信する条件: 1 件以上のメッセージを処理した場合のみ。
    全 DLQ が空だった場合はサマリーを送信しない（ノイズ削減）。

    Args:
        results:   DLQ ごとの処理結果リスト
        topic_arn: サマリー送信先 SNS トピック ARN
    """
    total_transient = sum(r.transient_count for r in results)
    total_permanent = sum(r.permanent_count for r in results)
    total_unknown   = sum(r.unknown_count   for r in results)
    total_errors    = sum(r.error_count     for r in results)
    total_processed = total_transient + total_permanent + total_unknown

    # 何も処理しなかった場合はサマリーを送らない（不要な通知を抑制する）
    if total_processed == 0 and total_errors == 0:
        logger.info("処理対象メッセージなし。サマリーの送信をスキップ")
        return

    # 各 DLQ の 7 日間累計件数を CloudWatch から取得する
    dlq_stats_lines = []
    for r in results:
        dlq_name = r.dlq_url.rstrip("/").split("/")[-1]
        seven_day_count = _get_7day_dlq_count(dlq_name)
        dlq_stats_lines.append(
            f"  {dlq_name}: 直近 7 日累計 {seven_day_count} 件"
        )

    dlq_stats_text = "\n".join(dlq_stats_lines) if dlq_stats_lines else "  （取得なし）"

    # アーカイブした S3 キーを最大 5 件表示する（通知の冗長化を防ぐ）
    all_s3_keys = [key for r in results for key in r.s3_keys]
    s3_keys_preview = "\n".join(f"  s3://.../{k}" for k in all_s3_keys[:5])
    if len(all_s3_keys) > 5:
        s3_keys_preview += f"\n  ... 他 {len(all_s3_keys) - 5} 件"

    subject = f"[SEP] DLQ 処理サマリー: 再処理 {total_transient}件 / 恒久 {total_permanent}件 / 不明 {total_unknown}件"

    message_body = (
        f"dlq-handler の処理が完了しました。\n\n"
        f"【処理結果】\n"
        f"  再処理（TRANSIENT） : {total_transient} 件\n"
        f"  S3 保存（PERMANENT）: {total_permanent} 件\n"
        f"  S3 保存（UNKNOWN）  : {total_unknown} 件\n"
        f"  処理エラー          : {total_errors} 件\n\n"
        f"【直近 7 日間の DLQ 累計件数】\n"
        f"{dlq_stats_text}\n\n"
        f"【アーカイブ先 S3 キー】\n"
        f"{s3_keys_preview if all_s3_keys else '  （なし）'}\n\n"
        f"処理エラーがある場合は CloudWatch Logs で詳細を確認してください。\n"
        f"  /aws/lambda/{os.environ.get('POWERTOOLS_SERVICE_NAME', 'sep-dlq-handler')}"
    )

    _sns_client.publish(
        TopicArn=topic_arn,
        Subject=subject,
        Message=message_body,
    )

    logger.info(
        "処理サマリーを SNS に送信",
        extra={
            "total_transient": total_transient,
            "total_permanent": total_permanent,
            "total_unknown": total_unknown,
            "total_errors": total_errors,
        },
    )


# ── Lambda ハンドラ ───────────────────────────────────────────


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics(capture_cold_start_metric=True)
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    """
    DLQ 監視・再処理ハンドラ。

    対応トリガー:
      1. EventBridge Scheduler（5 分ごと）: 定期的に DLQ を監視してドレインする
      2. EventBridge ルール（CloudWatch Alarm 状態変化）: DLQ 滞留時の即時起動

    処理フロー:
      1. 環境変数から DLQ → 元キューのマッピングを取得する
      2. 各 DLQ を _drain_dlq でドレインする（最大 _MAX_MESSAGES_PER_DLQ 件）
      3. 処理結果サマリーを SNS に送信する

    エラーハンドリング戦略:
      - _drain_dlq 自体が例外を throw した場合（SQS 接続エラーなど）は
        そのキューのエラーをログに残して残りの DLQ 処理を続行する。
        全 DLQ の処理後にサマリーを SNS に送信する。
      - DLQ が存在しない・権限がない場合は Lambda 全体をエラーにする
        （設定ミスとして迅速に検知するため）。

    Args:
        event:   EventBridge Scheduler または CloudWatch Alarm State Change のイベント dict
        context: Lambda コンテキスト（残り実行時間・メモリ情報など）

    Returns:
        処理結果のサマリー dict
    """
    # ── 環境変数の取得 ──────────────────────────────────────
    # ハードコード禁止（CLAUDE.md 禁止事項準拠）
    raw_mapping = get_env("DLQ_QUEUE_MAPPING")
    archive_bucket = get_env("DEAD_LETTER_ARCHIVE_BUCKET")
    alerts_topic_arn = get_env("ALERTS_SNS_TOPIC_ARN")

    # DLQ_QUEUE_MAPPING は {"dlq_url": "source_queue_url"} の JSON 文字列
    try:
        dlq_queue_mapping: dict[str, str] = json.loads(raw_mapping)
    except json.JSONDecodeError as e:
        logger.error(
            "DLQ_QUEUE_MAPPING の JSON パースに失敗しました",
            extra={"raw_mapping": raw_mapping[:200], "error": str(e)},
        )
        raise ValueError(f"DLQ_QUEUE_MAPPING が不正な JSON です: {e}") from e

    if not dlq_queue_mapping:
        logger.warning("DLQ_QUEUE_MAPPING が空です。処理をスキップします")
        return {"status": "skipped", "reason": "empty DLQ_QUEUE_MAPPING"}

    # トリガー種別をログに残す（スケジューラ起動 vs アラーム起動の判別）
    trigger_source = event.get("source", "unknown")
    logger.info(
        "dlq-handler 起動",
        extra={
            "trigger_source": trigger_source,
            "dlq_count": len(dlq_queue_mapping),
        },
    )

    # ── 各 DLQ をドレイン ───────────────────────────────────
    all_results: list[DlqProcessingResult] = []

    for dlq_url, source_queue_url in dlq_queue_mapping.items():
        try:
            result = _drain_dlq(
                dlq_url=dlq_url,
                source_queue_url=source_queue_url,
                archive_bucket=archive_bucket,
                alerts_topic_arn=alerts_topic_arn,
            )
            all_results.append(result)

        except Exception as e:
            # SQS 接続エラーなど予期しない例外が発生した場合でも
            # 他の DLQ の処理を継続するために例外を飲み込んでログに残す。
            # 処理エラーはメトリクスと SNS サマリーで通知される。
            logger.error(
                "DLQ ドレイン中に予期しない例外が発生",
                extra={
                    "dlq_url": dlq_url,
                    "error": str(e),
                    "error_type": type(e).__name__,
                },
            )
            # エラー集計のためダミー結果を追加する
            error_result = DlqProcessingResult(dlq_url=dlq_url, error_count=1)
            all_results.append(error_result)
            metrics.add_metric(name="DlqDrainErrors", unit=MetricUnit.Count, value=1)

    # ── 処理サマリーを SNS に送信 ───────────────────────────
    _send_summary(all_results, alerts_topic_arn)

    # ── レスポンス ──────────────────────────────────────────
    summary = {
        "status": "completed",
        "results": [
            {
                "dlq_url": r.dlq_url,
                "transient": r.transient_count,
                "permanent": r.permanent_count,
                "unknown": r.unknown_count,
                "errors": r.error_count,
            }
            for r in all_results
        ],
    }

    logger.info("dlq-handler 処理完了", extra={"summary": summary})
    return summary
