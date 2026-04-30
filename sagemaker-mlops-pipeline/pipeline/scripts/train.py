"""
学習スクリプト - SageMaker Training Job用

設計意図:
- XGBoostを使った汎用分類/回帰モデルのテンプレート
- SageMakerのハイパーパラメータ渡し規約に準拠
- モデルアーティファクトは /opt/ml/model/ に保存（SageMaker規約）
- 評価メトリクスをCloudWatch Metricsに出力（Pipelinesのメトリクスキャプチャ用）
"""
import argparse
import os
import joblib
import pandas as pd
import xgboost as xgb
from sklearn.metrics import accuracy_score
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


def train(train_dir: str, model_dir: str, hyperparams: dict) -> None:
    # 学習データ読み込み
    train_df = pd.read_csv(os.path.join(train_dir, 'train.csv'))
    X = train_df.drop('target', axis=1)
    y = train_df['target']

    # モデル学習
    model = xgb.XGBClassifier(
        n_estimators=int(hyperparams.get('n_estimators', 100)),
        max_depth=int(hyperparams.get('max_depth', 6)),
        learning_rate=float(hyperparams.get('learning_rate', 0.1)),
        random_state=42,
        eval_metric='logloss'
    )
    model.fit(X, y)

    # CloudWatch Metricsに出力（SageMakerがキャプチャ）
    train_acc = accuracy_score(y, model.predict(X))
    # 出力形式: "metricName: value" でCloudWatch Logsに書き出す
    print(f"train:accuracy: {train_acc:.4f}")
    logger.info(f"学習精度: {train_acc:.4f}")

    # モデル保存（SageMaker規約: /opt/ml/model/ に保存）
    os.makedirs(model_dir, exist_ok=True)
    joblib.dump(model, os.path.join(model_dir, 'model.joblib'))
    logger.info("モデル保存完了")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--n-estimators', type=int, default=100)
    parser.add_argument('--max-depth', type=int, default=6)
    parser.add_argument('--learning-rate', type=float, default=0.1)
    # SageMaker標準の環境変数からパスを取得
    parser.add_argument('--train', type=str,
                        default=os.environ.get('SM_CHANNEL_TRAIN', '/opt/ml/input/data/train'))
    parser.add_argument('--model-dir', type=str,
                        default=os.environ.get('SM_MODEL_DIR', '/opt/ml/model'))
    args = parser.parse_args()

    train(
        train_dir=args.train,
        model_dir=args.model_dir,
        hyperparams=vars(args)
    )
