"""
学習ステップビルダー

設計意図:
- XGBoost Estimator の設定とスポットインスタンス設定をここに集約
- max_wait >= max_run の制約はここで保証する（violation時にValueError）
- 呼び出し元はビルドされた TrainingStep と Estimator を受け取る
"""
from sagemaker.inputs import TrainingInput
from sagemaker.workflow.steps import ProcessingStep, TrainingStep
from sagemaker.xgboost import XGBoost


def build_training_step(
    role_arn: str,
    artifacts_bucket: str,
    processing_step: ProcessingStep,
    sagemaker_session,
    max_run: int = 3600,
    max_wait: int = 7200,
) -> tuple[TrainingStep, XGBoost]:
    """
    学習 TrainingStep と Estimator を生成して返す

    Returns:
        (TrainingStep, XGBoost): ConditionStep の register_step 生成に Estimator が必要なため両方返す
    """
    if max_wait < max_run:
        raise ValueError(f"max_wait ({max_wait}) は max_run ({max_run}) 以上である必要があります")

    estimator = XGBoost(
        entry_point="pipeline/scripts/train.py",
        framework_version="1.7-1",
        instance_type="ml.m5.xlarge",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session,
        # スポットインスタンスで学習コストを最大70%削減
        use_spot_instances=True,
        max_run=max_run,
        max_wait=max_wait,
        hyperparameters={
            "n-estimators": 100,
            "max-depth": 6,
            "learning-rate": 0.1,
        },
        output_path=f"s3://{artifacts_bucket}/model-artifacts/",
        metric_definitions=[
            {"Name": "train:accuracy", "Regex": "train:accuracy: ([0-9\\.]+)"}
        ],
    )

    step = TrainingStep(
        name="TrainingStep",
        estimator=estimator,
        inputs={
            "train": TrainingInput(
                s3_data=processing_step.properties.ProcessingOutputConfig.Outputs[
                    "train"
                ].S3Output.S3Uri
            )
        },
    )

    return step, estimator
