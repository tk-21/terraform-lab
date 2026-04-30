"""
SageMaker Pipelines定義

設計意図:
- このファイルが「パイプラインの設計図」。実行はしない
- 各ステップの構築ロジックは pipeline/steps/ に分離し、ここはオーケストレーションに集中
- terraform/modules/pipeline/ からこのファイルを参照してPipeline定義JSONを生成
- または `python pipeline_definition.py --action upsert` で直接デプロイも可能
- 汎用テンプレートとして、model_package_group_name と threshold のみ変えれば転用可能

パイプラインステップ:
  1. ProcessingStep: 前処理
  2. TrainingStep: 学習（スポットインスタンス）
  3. ProcessingStep: 評価
  4. ConditionStep: 精度閾値チェック
  5a. RegisterModel: 合格時 → Model Registry (PendingApproval)
  5b. FailStep: 不合格時 → パイプライン失敗
"""
import argparse

import boto3
import sagemaker
from sagemaker.workflow.parameters import ParameterFloat, ParameterString
from sagemaker.workflow.pipeline import Pipeline

from pipeline.steps.evaluation import build_evaluation_step
from pipeline.steps.processing import build_processing_step
from pipeline.steps.register import build_condition_step
from pipeline.steps.training import build_training_step

REGION = "ap-northeast-1"
PREFIX = "smp"


def get_pipeline(
    role_arn: str,
    artifacts_bucket: str,
    data_bucket: str,
    pipeline_name: str = f"{PREFIX}-training-pipeline",
    model_package_group_name: str = f"{PREFIX}-model-group",
) -> Pipeline:

    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    # パイプラインパラメータ（実行時に上書き可能）
    accuracy_threshold = ParameterFloat(name="AccuracyThreshold", default_value=0.8)
    input_data_uri = ParameterString(
        name="InputDataUri",
        default_value=f"s3://{data_bucket}/raw/",
    )

    # 各ステップを steps/ モジュールから生成
    processing_step = build_processing_step(
        role_arn=role_arn,
        artifacts_bucket=artifacts_bucket,
        input_data_uri=input_data_uri,
        sagemaker_session=sagemaker_session,
    )

    training_step, xgb_estimator = build_training_step(
        role_arn=role_arn,
        artifacts_bucket=artifacts_bucket,
        processing_step=processing_step,
        sagemaker_session=sagemaker_session,
    )

    evaluation_step, evaluation_report = build_evaluation_step(
        role_arn=role_arn,
        artifacts_bucket=artifacts_bucket,
        training_step=training_step,
        processing_step=processing_step,
        sagemaker_session=sagemaker_session,
    )

    condition_step = build_condition_step(
        role_arn=role_arn,
        artifacts_bucket=artifacts_bucket,
        training_step=training_step,
        evaluation_step=evaluation_step,
        evaluation_report=evaluation_report,
        accuracy_threshold=accuracy_threshold,
        model_package_group_name=model_package_group_name,
        xgb_estimator=xgb_estimator,
        sagemaker_session=sagemaker_session,
    )

    pipeline = Pipeline(
        name=pipeline_name,
        parameters=[accuracy_threshold, input_data_uri],
        steps=[processing_step, training_step, evaluation_step, condition_step],
        sagemaker_session=sagemaker_session,
    )

    return pipeline


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["upsert", "definition"], default="definition")
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--artifacts-bucket", required=True)
    parser.add_argument("--data-bucket", required=True)
    args = parser.parse_args()

    pipeline = get_pipeline(
        role_arn=args.role_arn,
        artifacts_bucket=args.artifacts_bucket,
        data_bucket=args.data_bucket,
    )

    if args.action == "upsert":
        pipeline.upsert(role_arn=args.role_arn)
        print("Pipeline upsert完了")
    else:
        import json
        print(json.dumps(json.loads(pipeline.definition()), indent=2))
