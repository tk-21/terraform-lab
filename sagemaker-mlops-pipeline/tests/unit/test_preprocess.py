"""
pipeline/scripts/preprocess.py のユニットテスト

設計意図:
- SageMaker環境なしでロジックを検証するため、ファイルI/Oのみでテスト
- 欠損値除去・標準化・分割の各処理が正しく動作することを確認
"""
import os
import sys
import tempfile

import pandas as pd
import pytest
from sklearn.datasets import make_classification

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "../.."))
from pipeline.scripts.preprocess import preprocess


@pytest.fixture
def sample_csv(tmp_path):
    """テスト用CSVファイルを一時ディレクトリに生成"""
    X, y = make_classification(n_samples=100, n_features=5, random_state=42)
    df = pd.DataFrame(X, columns=[f"feature_{i}" for i in range(5)])
    df["target"] = y
    input_dir = tmp_path / "input"
    input_dir.mkdir()
    df.to_csv(input_dir / "data.csv", index=False)
    return str(input_dir)


def test_preprocess_creates_output_files(sample_csv, tmp_path):
    train_dir = str(tmp_path / "train")
    test_dir = str(tmp_path / "test")

    preprocess(sample_csv, train_dir, test_dir)

    assert os.path.exists(os.path.join(train_dir, "train.csv"))
    assert os.path.exists(os.path.join(test_dir, "test.csv"))


def test_preprocess_split_ratio(sample_csv, tmp_path):
    train_dir = str(tmp_path / "train")
    test_dir = str(tmp_path / "test")

    preprocess(sample_csv, train_dir, test_dir, test_size=0.2)

    train_df = pd.read_csv(os.path.join(train_dir, "train.csv"))
    test_df = pd.read_csv(os.path.join(test_dir, "test.csv"))
    total = len(train_df) + len(test_df)

    assert total == 100
    assert abs(len(test_df) / total - 0.2) < 0.05


def test_preprocess_no_missing_values(tmp_path):
    """欠損値を含む入力データが正しく除去されることを確認"""
    df = pd.DataFrame({
        "feature_0": [1.0, 2.0, None, 4.0],
        "feature_1": [0.5, 1.5, 2.5, 3.5],
        "target": [0, 1, 0, 1],
    })
    input_dir = tmp_path / "input"
    input_dir.mkdir()
    df.to_csv(input_dir / "data.csv", index=False)

    train_dir = str(tmp_path / "train")
    test_dir = str(tmp_path / "test")
    preprocess(str(input_dir), train_dir, test_dir)

    train_df = pd.read_csv(os.path.join(train_dir, "train.csv"))
    test_df = pd.read_csv(os.path.join(test_dir, "test.csv"))
    combined = pd.concat([train_df, test_df])
    assert combined.isnull().sum().sum() == 0


def test_preprocess_empty_dir_raises(tmp_path):
    """CSVファイルが存在しないディレクトリは ValueError を送出することを確認"""
    empty_dir = str(tmp_path / "empty")
    os.makedirs(empty_dir)

    with pytest.raises(ValueError, match="CSVファイルが見つかりません"):
        preprocess(empty_dir, str(tmp_path / "train"), str(tmp_path / "test"))
