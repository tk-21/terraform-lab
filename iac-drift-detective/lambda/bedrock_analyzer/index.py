"""
bedrock-analyzer Lambda ハンドラー
Step FunctionsからDrift DetectorのDrift結果を受け取り、Bedrockで分析してS3にレポートを保存する
"""

import json
import os
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

from analyzer import analyze_drifts

logger = Logger()
tracer = Tracer()

# 環境変数から設定値を取得
REPORTS_BUCKET = os.environ["REPORTS_BUCKET"]
BEDROCK_REGION = os.environ.get("BEDROCK_REGION", "us-east-1")


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    Step Functionsから呼び出されるメインハンドラー。
    drift-detectorの出力を受け取り、Bedrock分析結果をS3に保存して返す。
    """
    # 入力からdriftsリストを取得
    drifts = event.get("drifts", [])
    logger.info("Bedrock分析開始", extra={"drift_count": len(drifts)})

    # Bedrockでドリフトを分析（バリデーション失敗時はValueErrorが上がりStep FunctionsがTaskFailedを発行）
    analysis_result = analyze_drifts(drifts)
    logger.info("Bedrock分析完了", extra={"severity": analysis_result.get("severity")})

    # 分析タイムスタンプを記録
    analysis_timestamp = datetime.now(timezone.utc).isoformat()

    # S3にレポートを保存
    # キー形式: reports/{YYYY/MM/DD}/drift-report-{timestamp_compact}.json
    now = datetime.now(timezone.utc)
    date_path = now.strftime("%Y/%m/%d")
    timestamp_compact = now.strftime("%Y%m%dT%H%M%SZ")
    report_s3_key = f"reports/{date_path}/drift-report-{timestamp_compact}.json"

    # S3に保存するレポートデータ（分析結果 + 元のドリフト情報）
    report_data = {
        **analysis_result,
        "original_drifts": drifts,
        "analysis_timestamp": analysis_timestamp,
    }

    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=REPORTS_BUCKET,
        Key=report_s3_key,
        Body=json.dumps(report_data, ensure_ascii=False, indent=2),
        ContentType="application/json",
    )
    logger.info("S3レポート保存完了", extra={"bucket": REPORTS_BUCKET, "key": report_s3_key})

    # Step Functionsへの出力（分析結果 + 元ドリフト情報 + メタデータ）
    return {
        **analysis_result,
        "original_drifts": drifts,
        "analysis_timestamp": analysis_timestamp,
        "report_s3_key": report_s3_key,
    }
