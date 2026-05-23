"""
前処理コンテナ: S3から入力データを取得し、正規化してS3に書き戻す
Step Functionsから環境変数でS3キー等を受け取る設計
"""
import os
import json
import logging
import boto3
import pandas as pd
from io import StringIO, BytesIO

# Lambdaと同じ形式でログ出力（CloudWatch Insights対応）
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)


def get_env(key: str) -> str:
    """必須環境変数を取得。未設定なら即座に失敗させる"""
    value = os.environ.get(key)
    if not value:
        raise ValueError(f"必須環境変数 {key} が未設定です")
    return value


def load_from_s3(s3_client, bucket: str, key: str) -> dict | list:
    """S3からJSONまたはCSVを読み込んでPythonオブジェクトに変換"""
    logger.info(f"S3から読み込み開始: s3://{bucket}/{key}")
    response = s3_client.get_object(Bucket=bucket, Key=key)
    content = response["Body"].read().decode("utf-8")

    if key.endswith(".json"):
        return json.loads(content)
    elif key.endswith(".csv"):
        df = pd.read_csv(StringIO(content))
        return df.to_dict(orient="records")
    else:
        raise ValueError(f"サポートされていないファイル形式: {key}")


def preprocess(records: list) -> dict:
    """
    データクレンジングと正規化
    - 空文字列/Noneをフィルタ
    - テキストフィールドの前後空白除去
    - Bedrock向けのプロンプト構造に整形
    """
    df = pd.DataFrame(records)

    # 全列の文字列フィールドをstrip
    str_cols = df.select_dtypes(include="object").columns
    df[str_cols] = df[str_cols].apply(lambda col: col.str.strip())

    # 空行を除去
    df.dropna(how="all", inplace=True)

    # Bedrockに渡すための構造化データに変換
    processed_records = df.to_dict(orient="records")

    return {
        "record_count": len(processed_records),
        "records": processed_records,
        "columns": list(df.columns),
    }


def save_to_s3(s3_client, bucket: str, key: str, data: dict) -> str:
    """前処理済みデータをJSONとしてS3に保存"""
    output_key = key.replace("input/", "processed/").replace(".csv", ".json")
    body = json.dumps(data, ensure_ascii=False, indent=2)

    s3_client.put_object(
        Bucket=bucket,
        Key=output_key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )
    logger.info(f"S3への保存完了: s3://{bucket}/{output_key}")
    return output_key


def main():
    input_bucket = get_env("INPUT_BUCKET")
    output_bucket = get_env("OUTPUT_BUCKET")
    s3_key = get_env("S3_KEY")
    job_id = os.environ.get("JOB_ID", "unknown")

    logger.info(f"前処理開始: job_id={job_id}, key={s3_key}")

    s3 = boto3.client("s3")

    # 入力データ取得
    raw_data = load_from_s3(s3, input_bucket, s3_key)
    if isinstance(raw_data, dict):
        records = raw_data.get("records", [raw_data])
    else:
        records = raw_data

    # 前処理実行
    processed = preprocess(records)
    processed["job_id"] = job_id
    processed["source_key"] = s3_key

    # 処理済みデータ保存
    output_key = save_to_s3(s3, output_bucket, s3_key, processed)

    logger.info(f"前処理完了: records={processed['record_count']}, output_key={output_key}")

    # Step Functionsが次のステートで使うための出力（stdout）
    print(json.dumps({
        "status": "success",
        "job_id": job_id,
        "output_key": output_key,
        "record_count": processed["record_count"],
    }))


if __name__ == "__main__":
    main()
