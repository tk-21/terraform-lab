"""
前処理スクリプト - SageMaker Processing Job用

設計意図:
- このスクリプトはモデル非依存の汎用テンプレート
- 実際のユースケースではここに特徴量エンジニアリングを追加する
- 入力: /opt/ml/processing/input/raw/ にCSVファイル
- 出力: /opt/ml/processing/output/train/ と /test/ に分割済みデータ
"""
import argparse
import os
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)


def preprocess(input_dir: str, output_train_dir: str, output_test_dir: str,
               test_size: float = 0.2) -> None:
    """
    データ前処理のメイン処理
    - 欠損値除去
    - 標準化
    - 学習/テスト分割
    """
    # 入力ファイルの読み込み
    input_files = [f for f in os.listdir(input_dir) if f.endswith('.csv')]
    if not input_files:
        raise ValueError(f"CSVファイルが見つかりません: {input_dir}")

    dfs = [pd.read_csv(os.path.join(input_dir, f)) for f in input_files]
    df = pd.concat(dfs, ignore_index=True)
    logger.info(f"入力データ: {len(df)}行, {len(df.columns)}列")

    # 欠損値除去
    df = df.dropna()
    logger.info(f"欠損値除去後: {len(df)}行")

    # 数値列の標準化（目的変数列 'target' を除く）
    feature_cols = [c for c in df.select_dtypes(include='number').columns if c != 'target']
    scaler = StandardScaler()
    df[feature_cols] = scaler.fit_transform(df[feature_cols])

    # 学習/テスト分割
    train_df, test_df = train_test_split(df, test_size=test_size, random_state=42)
    logger.info(f"学習データ: {len(train_df)}行 / テストデータ: {len(test_df)}行")

    # 出力
    os.makedirs(output_train_dir, exist_ok=True)
    os.makedirs(output_test_dir, exist_ok=True)
    train_df.to_csv(os.path.join(output_train_dir, 'train.csv'), index=False)
    test_df.to_csv(os.path.join(output_test_dir, 'test.csv'), index=False)
    logger.info("前処理完了")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--test-size', type=float, default=0.2)
    args = parser.parse_args()

    preprocess(
        input_dir='/opt/ml/processing/input/raw',
        output_train_dir='/opt/ml/processing/output/train',
        output_test_dir='/opt/ml/processing/output/test',
        test_size=args.test_size
    )
