"""
Data Quality Monitorのベースライン生成

設計意図:
- 学習時のデータ統計情報（平均・分散・データ型・欠損率など）をベースラインとして記録
- SageMaker Model Monitorがこのベースラインと本番推論時の入力データを比較
- ベースラインはS3に保存され、Monitorスケジュール設定時に参照される
"""
import boto3
import sagemaker
from sagemaker.model_monitor import DefaultModelMonitor
from sagemaker.model_monitor.dataset_format import DatasetFormat

REGION = "ap-northeast-1"
PREFIX = "smp"


def create_data_quality_baseline(
    role_arn: str,
    artifacts_bucket: str,
    data_bucket: str
) -> str:
    """
    Data Quality Monitorのベースラインジョブを実行

    Returns:
        str: ベースライン統計のS3 URI
    """
    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    monitor = DefaultModelMonitor(
        role=role_arn,
        instance_count=1,
        instance_type="ml.m5.large",
        volume_size_in_gb=20,
        max_runtime_in_seconds=3600,
        sagemaker_session=sagemaker_session
    )

    baseline_output_uri = f"s3://{artifacts_bucket}/monitor/data-quality/baseline"

    # ベースラインジョブ実行（学習データを使ってベースライン統計を計算）
    monitor.suggest_baseline(
        baseline_dataset=f"s3://{data_bucket}/raw/sample_data.csv",
        dataset_format=DatasetFormat.csv(header=True),
        output_s3_uri=baseline_output_uri,
        wait=True,
        logs=True
    )

    print(f"Data Qualityベースライン生成完了: {baseline_output_uri}")
    return baseline_output_uri


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--artifacts-bucket", required=True)
    parser.add_argument("--data-bucket", required=True)
    args = parser.parse_args()

    create_data_quality_baseline(
        role_arn=args.role_arn,
        artifacts_bucket=args.artifacts_bucket,
        data_bucket=args.data_bucket
    )
