"""
ingestor バリデーションロジック

SQS メッセージボディ（S3 イベント通知）の解析と
S3 オブジェクトのフォーマット判定を担う。

ハンドラから分離することで単体テストを容易にする。
"""

import json
from typing import NamedTuple


class S3Object(NamedTuple):
    """S3 オブジェクト情報のデータクラス（イミュータブルな NamedTuple）"""

    bucket: str  # S3 バケット名
    key: str  # S3 オブジェクトキー（URL エンコードされた場合は decode 済み）
    size: int  # オブジェクトサイズ（バイト）


def parse_s3_notification(sqs_body: str) -> list[S3Object]:
    """
    SQS メッセージボディから S3 オブジェクト情報を抽出する。

    S3 → SQS 直接通知の場合、SQS メッセージボディは S3 イベント通知 JSON になる。
    （S3 → SNS → SQS の場合は SNS エンベロープが追加されるが、このパイプラインでは直接通知）

    処理するイベント: ObjectCreated:* (Put / Post / Copy / CompleteMultipartUpload)
    スキップするイベント:
      - s3:TestEvent （バケット通知設定時に S3 が送信するテストイベント）
      - ObjectCreated 以外のイベント（ObjectRemoved など）

    Args:
        sqs_body: SQS メッセージの body フィールド（JSON 文字列）

    Returns:
        処理対象の S3Object リスト。テストイベントや対象外イベントは空リストを返す。

    Raises:
        ValueError: JSON のパースに失敗した場合、または必須フィールドが欠落している場合
    """
    try:
        body = json.loads(sqs_body)
    except json.JSONDecodeError as e:
        raise ValueError(f"SQS メッセージボディが有効な JSON ではありません: {e}") from e

    # S3 テストイベント: バケット通知設定時に S3 が送信する確認用イベント
    # "Event" キーが存在する場合はテストイベントとして除外する
    if body.get("Event") == "s3:TestEvent":
        return []

    records = body.get("Records", [])
    if not records:
        return []

    s3_objects = []
    for record in records:
        event_name = record.get("eventName", "")

        # ObjectCreated 系イベントのみを処理対象とする
        # ObjectRemoved・ObjectRestore などは ingestor の処理対象外
        if not event_name.startswith("ObjectCreated"):
            continue

        s3_info = record.get("s3", {})
        bucket_name = s3_info.get("bucket", {}).get("name", "")
        object_info = s3_info.get("object", {})

        # S3 オブジェクトキーは URL エンコードされているため decode する
        # 例: "path%2Fto%2Ffile.json" → "path/to/file.json"
        # スペースは "+" ではなく "%20" でエンコードされる点に注意
        raw_key = object_info.get("key", "")
        from urllib.parse import unquote_plus

        decoded_key = unquote_plus(raw_key)

        if not bucket_name or not decoded_key:
            continue

        s3_objects.append(
            S3Object(
                bucket=bucket_name,
                key=decoded_key,
                size=object_info.get("size", 0),
            )
        )

    return s3_objects


def detect_format(key: str) -> str:
    """
    S3 オブジェクトキーのファイル拡張子からフォーマットを判定する。

    対応フォーマット:
      .json → "json" （単一オブジェクトまたは配列）
      .csv  → "csv"  （ヘッダー行付きの CSV）

    Args:
        key: S3 オブジェクトキー（例: raw/2024/01/events.json）

    Returns:
        "json" または "csv"

    Raises:
        ValueError: 対応していない拡張子の場合
    """
    lower_key = key.lower()

    if lower_key.endswith(".json"):
        return "json"
    elif lower_key.endswith(".csv"):
        return "csv"
    else:
        raise ValueError(
            f"未対応のファイル形式です。.json または .csv のファイルを配置してください: {key}"
        )
