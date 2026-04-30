"""
評価スクリプト - SageMaker Processing Job（評価用）

設計意図:
- モデルアーティファクトとテストデータを受け取り精度を評価
- 評価結果をevaluation.jsonとして出力
- SageMaker Pipelines の ConditionStep がこのJSONを参照して
  Model Registryへの登録可否を判定する
- 出力形式はSageMaker Clarify互換のMetricsJSON形式に準拠
"""
import json
import os
import joblib
import pandas as pd
from sklearn.metrics import accuracy_score, classification_report
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


def evaluate(model_dir: str, test_dir: str, output_dir: str) -> None:
    # モデル読み込み
    model = joblib.load(os.path.join(model_dir, 'model.joblib'))

    # テストデータ読み込み
    test_df = pd.read_csv(os.path.join(test_dir, 'test.csv'))
    X_test = test_df.drop('target', axis=1)
    y_test = test_df['target']

    # 評価
    y_pred = model.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    report = classification_report(y_test, y_pred, output_dict=True)

    logger.info(f"テスト精度: {accuracy:.4f}")
    logger.info(f"分類レポート:\n{classification_report(y_test, y_pred)}")

    # SageMaker Pipelines ConditionStep互換のJSON形式で出力
    evaluation_report = {
        "classification_metrics": {
            "accuracy": {
                "value": accuracy,
                "standard_deviation": "NaN"
            }
        },
        "regression_metrics": {}
    }

    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, 'evaluation.json')
    with open(output_path, 'w') as f:
        json.dump(evaluation_report, f)

    logger.info(f"評価レポート保存完了: {output_path}")


if __name__ == '__main__':
    evaluate(
        model_dir='/opt/ml/processing/model',
        test_dir='/opt/ml/processing/input/test',
        output_dir='/opt/ml/processing/evaluation'
    )
