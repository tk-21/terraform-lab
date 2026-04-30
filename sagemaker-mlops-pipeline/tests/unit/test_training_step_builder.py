"""
pipeline/steps/training.py のユニットテスト

設計意図:
- SageMaker APIを呼ばずにバリデーションロジックのみを検証
- max_wait < max_run の組み合わせが正しく拒否されることを確認
"""
import pytest


def test_max_wait_less_than_max_run_raises():
    """max_wait < max_run のときに ValueError が送出されることを確認"""
    from pipeline.steps.training import build_training_step

    with pytest.raises(ValueError, match="max_wait"):
        build_training_step(
            role_arn="arn:aws:iam::123456789012:role/test-role",
            artifacts_bucket="test-bucket",
            processing_step=None,
            sagemaker_session=None,
            max_run=3600,
            max_wait=1800,  # max_run より小さい → ValueError
        )
