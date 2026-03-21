"""
Firehose Transformation Lambda

役割:
  1. Base64 デコード → JSON パース
  2. 必須フィールドのバリデーション
  3. ingested_at タイムスタンプを付与
  4. Base64 再エンコードして Firehose に返す

Firehose が期待するレスポンス:
  - result: "Ok" | "ProcessingFailed" | "Dropped"
  - ProcessingFailed の場合、Firehose はエラープレフィックスに書き込む
"""

import base64
import json
from datetime import datetime, timezone

REQUIRED_FIELDS = {"event_id", "event_type", "user_id", "tenant_id", "timestamp"}


def lambda_handler(event: dict, context) -> dict:
    output = []

    for record in event["records"]:
        try:
            # 1. デコード & パース
            payload = json.loads(
                base64.b64decode(record["data"]).decode("utf-8")
            )

            # 2. バリデーション
            missing = REQUIRED_FIELDS - payload.keys()
            if missing:
                raise ValueError(f"Missing required fields: {missing}")

            # 3. ingested_at 付与（UTC ISO8601）
            payload["ingested_at"] = datetime.now(timezone.utc).strftime(
                "%Y-%m-%dT%H:%M:%S.%f"
            ) + "Z"

            # 4. 再エンコード（改行は AppendDelimiterToRecord プロセッサが付与）
            data = base64.b64encode(
                json.dumps(payload, ensure_ascii=False).encode("utf-8")
            ).decode("utf-8")

            output.append(
                {"recordId": record["recordId"], "result": "Ok", "data": data}
            )

        except Exception as exc:
            print(
                f"[ProcessingFailed] recordId={record['recordId']} error={exc}"
            )
            # 失敗レコードは Firehose がエラープレフィックスに書き込む
            output.append(
                {
                    "recordId": record["recordId"],
                    "result": "ProcessingFailed",
                    "data": record["data"],
                }
            )

    return {"records": output}
