"""
pipeline/scripts/evaluate.py のユニットテスト

設計意図:
- 評価結果 JSON の出力形式が ConditionStep の json_path と一致することを確認
- json_path: classification_metrics.accuracy.value
- SageMaker環境なしでテストするため、joblib でモデルを一時保存して使用
"""
import json
import os
import sys

import joblib
import pandas as pd
import pytest
from sklearn.datasets import make_classification
from sklearn.dummy import DummyClassifier

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))
from pipeline.scripts.evaluate import evaluate


@pytest.fixture
def model_and_test_data(tmp_path):
    """ダミーモデルとテストデータを一時ディレクトリに用意"""
    X, y = make_classification(n_samples=100, n_features=5, random_state=42)
    clf = DummyClassifier(strategy="most_frequent")
    clf.fit(X, y)

    model_dir = tmp_path / "model"
    model_dir.mkdir()
    joblib.dump(clf, model_dir / "model.joblib")

    test_df = pd.DataFrame(X, columns=[f"feature_{i}" for i in range(5)])
    test_df["target"] = y
    test_dir = tmp_path / "test"
    test_dir.mkdir()
    test_df.to_csv(test_dir / "test.csv", index=False)

    return str(model_dir), str(test_dir)


def test_evaluate_creates_json(model_and_test_data, tmp_path):
    model_dir, test_dir = model_and_test_data
    output_dir = str(tmp_path / "output")

    evaluate(model_dir, test_dir, output_dir)

    assert os.path.exists(os.path.join(output_dir, "evaluation.json"))


def test_evaluate_json_schema(model_and_test_data, tmp_path):
    """ConditionStep の json_path (classification_metrics.accuracy.value) と一致することを確認"""
    model_dir, test_dir = model_and_test_data
    output_dir = str(tmp_path / "output")

    evaluate(model_dir, test_dir, output_dir)

    with open(os.path.join(output_dir, "evaluation.json")) as f:
        report = json.load(f)

    assert "classification_metrics" in report
    assert "accuracy" in report["classification_metrics"]
    assert "value" in report["classification_metrics"]["accuracy"]
    accuracy = report["classification_metrics"]["accuracy"]["value"]
    assert 0.0 <= accuracy <= 1.0


def test_evaluate_accuracy_range(model_and_test_data, tmp_path):
    """accuracy が 0.0〜1.0 の範囲に収まることを確認"""
    model_dir, test_dir = model_and_test_data
    output_dir = str(tmp_path / "output")

    evaluate(model_dir, test_dir, output_dir)

    with open(os.path.join(output_dir, "evaluation.json")) as f:
        report = json.load(f)

    accuracy = report["classification_metrics"]["accuracy"]["value"]
    assert 0.0 <= accuracy <= 1.0
