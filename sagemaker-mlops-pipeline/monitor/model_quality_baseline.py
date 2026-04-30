"""
Model Quality Monitorのベースライン生成

設計意図:
- テストデータに対するモデルの予測結果と正解ラベルを使ってベースラインを生成
- 本番推論時の実際の予測精度とこのベースラインを比較してモデル劣化を検知
- Ground Truth（正解ラベル）は後からS3に格納される前提で設計
"""
import boto3
import sagemaker
from sagemaker.model_monitor import ModelQualityMonitor
from sagemaker.model_monitor.dataset_format import DatasetFormat

REGION = "ap-northeast-1"
PREFIX = "smp"


def create_model_quality_baseline(
    role_arn: str,
    artifacts_bucket: str,
    endpoint_name: str = f"{PREFIX}-inference-endpoint"
) -> str:
    """
    Model Quality Monitorのベースラインジョブを実行

    Returns:
        str: ベースライン制約のS3 URI
    """
    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    monitor = ModelQualityMonitor(
        role=role_arn,
        instance_count=1,
        instance_type="ml.m5.large",
        sagemaker_session=sagemaker_session
    )

    baseline_output_uri = f"s3://{artifacts_bucket}/monitor/model-quality/baseline"

    monitor.suggest_baseline(
        baseline_dataset=f"s3://{artifacts_bucket}/pipeline-artifacts/test/test.csv",
        dataset_format=DatasetFormat.csv(header=True),
        output_s3_uri=baseline_output_uri,
        problem_type="BinaryClassification",
        inference_attribute="prediction",      # 推論結果のカラム名
        ground_truth_attribute="target",       # 正解ラベルのカラム名
        wait=True
    )

    print(f"Model Qualityベースライン生成完了: {baseline_output_uri}")
    return baseline_output_uri


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--artifacts-bucket", required=True)
    parser.add_argument("--endpoint-name", default=f"{PREFIX}-inference-endpoint")
    args = parser.parse_args()

    create_model_quality_baseline(
        role_arn=args.role_arn,
        artifacts_bucket=args.artifacts_bucket,
        endpoint_name=args.endpoint_name
    )
