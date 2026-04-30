"""
モデル登録・条件分岐ステップビルダー

設計意図:
- ConditionStep (精度チェック) / RegisterModel (合格) / FailStep (不合格) をまとめて生成
- 精度閾値は呼び出し元の ParameterFloat から受け取ることで実行時に変更可能
- 承認ステータスは必ず PendingApproval で登録し、人間承認を挟む設計
"""
from sagemaker.model import Model
from sagemaker.model_metrics import MetricsSource, ModelMetrics
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.conditions import ConditionGreaterThanOrEqualTo
from sagemaker.workflow.fail_step import FailStep
from sagemaker.workflow.functions import JsonGet
from sagemaker.workflow.model_step import ModelStep
from sagemaker.workflow.parameters import ParameterFloat
from sagemaker.workflow.properties import PropertyFile
from sagemaker.workflow.steps import ProcessingStep, TrainingStep
from sagemaker.xgboost import XGBoost


def build_condition_step(
    role_arn: str,
    artifacts_bucket: str,
    training_step: TrainingStep,
    evaluation_step: ProcessingStep,
    evaluation_report: PropertyFile,
    accuracy_threshold: ParameterFloat,
    model_package_group_name: str,
    xgb_estimator: XGBoost,
    sagemaker_session,
) -> ConditionStep:
    """
    RegisterModel / FailStep / ConditionStep を生成して返す

    評価結果の json_path は evaluate.py の出力キー構造と必ず一致させること:
      classification_metrics.accuracy.value
    """
    model_metrics = ModelMetrics(
        model_statistics=MetricsSource(
            s3_uri=f"s3://{artifacts_bucket}/pipeline-artifacts/evaluation/evaluation.json",
            content_type="application/json",
        )
    )

    register_step = ModelStep(
        name="RegisterModelStep",
        step_args=Model(
            image_uri=xgb_estimator.training_image_uri(),
            model_data=training_step.properties.ModelArtifacts.S3ModelArtifacts,
            role=role_arn,
            sagemaker_session=sagemaker_session,
        ).register(
            content_types=["application/json"],
            response_types=["application/json"],
            inference_instances=["ml.t2.medium", "ml.m5.large"],
            transform_instances=["ml.m5.large"],
            model_package_group_name=model_package_group_name,
            # 必ず人間承認を経てからデプロイされるよう PendingApproval で登録
            approval_status="PendingApproval",
            model_metrics=model_metrics,
        ),
    )

    fail_step = FailStep(
        name="ModelEvaluationFailed",
        error_message="モデル評価が精度閾値を満たしませんでした。学習パラメータを見直してください。",
    )

    accuracy_condition = ConditionGreaterThanOrEqualTo(
        left=JsonGet(
            step_name=evaluation_step.name,
            property_file=evaluation_report,
            json_path="classification_metrics.accuracy.value",
        ),
        right=accuracy_threshold,
    )

    return ConditionStep(
        name="CheckAccuracyCondition",
        conditions=[accuracy_condition],
        if_steps=[register_step],
        else_steps=[fail_step],
    )
