"""
前処理ステップビルダー

設計意図:
- pipeline_definition.py から呼び出されるステップ生成の責務を分離
- SKLearnProcessor + ProcessingStep の組み立てをここに集約
- コード変更なしでインスタンスタイプや入出力パスを呼び出し元から差し替え可能
"""
from sagemaker.processing import ProcessingInput, ProcessingOutput
from sagemaker.sklearn.processing import SKLearnProcessor
from sagemaker.workflow.parameters import ParameterString
from sagemaker.workflow.steps import ProcessingStep


def build_processing_step(
    role_arn: str,
    artifacts_bucket: str,
    input_data_uri: ParameterString,
    sagemaker_session,
) -> ProcessingStep:
    """前処理 ProcessingStep を生成して返す"""
    processor = SKLearnProcessor(
        framework_version="1.2-1",
        instance_type="ml.m5.large",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session,
        tags=[{"Key": "Project", "Value": "sagemaker-mlops-pipeline"}],
    )

    return ProcessingStep(
        name="PreprocessingStep",
        processor=processor,
        inputs=[
            ProcessingInput(
                source=input_data_uri,
                destination="/opt/ml/processing/input/raw",
            )
        ],
        outputs=[
            ProcessingOutput(
                output_name="train",
                source="/opt/ml/processing/output/train",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/train",
            ),
            ProcessingOutput(
                output_name="test",
                source="/opt/ml/processing/output/test",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/test",
            ),
        ],
        code="pipeline/scripts/preprocess.py",
    )
