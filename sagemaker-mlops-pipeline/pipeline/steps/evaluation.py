"""
評価ステップビルダー

設計意図:
- 評価用 ProcessingStep と PropertyFile をセットで生成
- PropertyFile は ConditionStep が accuracy 値を読み取るために必須
- json_path は evaluate.py の出力形式 (classification_metrics.accuracy.value) と一致させること
"""
from sagemaker.processing import ProcessingInput, ProcessingOutput
from sagemaker.sklearn.processing import SKLearnProcessor
from sagemaker.workflow.properties import PropertyFile
from sagemaker.workflow.steps import ProcessingStep, TrainingStep


def build_evaluation_step(
    role_arn: str,
    artifacts_bucket: str,
    training_step: TrainingStep,
    processing_step: ProcessingStep,
    sagemaker_session,
) -> tuple[ProcessingStep, PropertyFile]:
    """
    評価 ProcessingStep と PropertyFile を生成して返す

    Returns:
        (ProcessingStep, PropertyFile): ConditionStep の JsonGet に PropertyFile が必要なため両方返す
    """
    processor = SKLearnProcessor(
        framework_version="1.2-1",
        instance_type="ml.m5.large",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session,
    )

    # ConditionStep が accuracy 値を参照するための PropertyFile
    evaluation_report = PropertyFile(
        name="EvaluationReport",
        output_name="evaluation",
        path="evaluation.json",
    )

    step = ProcessingStep(
        name="EvaluationStep",
        processor=processor,
        inputs=[
            ProcessingInput(
                source=training_step.properties.ModelArtifacts.S3ModelArtifacts,
                destination="/opt/ml/processing/model",
            ),
            ProcessingInput(
                source=processing_step.properties.ProcessingOutputConfig.Outputs[
                    "test"
                ].S3Output.S3Uri,
                destination="/opt/ml/processing/input/test",
            ),
        ],
        outputs=[
            ProcessingOutput(
                output_name="evaluation",
                source="/opt/ml/processing/evaluation",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/evaluation",
            )
        ],
        code="pipeline/scripts/evaluate.py",
        property_files=[evaluation_report],
    )

    return step, evaluation_report
