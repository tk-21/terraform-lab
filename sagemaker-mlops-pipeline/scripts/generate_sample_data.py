"""
動作確認用サンプルデータ生成

設計意図:
- 実際のユースケースデータがない状態でパイプラインをE2Eテストするためのダミーデータ
- sklearn.datasets.make_classificationで2クラス分類データを生成
- 生成後にS3データバケットへアップロード
"""
import os
import boto3
import pandas as pd
from sklearn.datasets import make_classification
import argparse


def generate_and_upload(bucket_name: str, n_samples: int = 1000) -> None:
    X, y = make_classification(
        n_samples=n_samples,
        n_features=10,
        n_informative=5,
        random_state=42
    )

    df = pd.DataFrame(X, columns=[f"feature_{i}" for i in range(10)])
    df['target'] = y

    local_path = os.path.join(os.environ.get('TMPDIR', '/tmp'), 'sample_data.csv')
    df.to_csv(local_path, index=False)

    s3 = boto3.client('s3', region_name='ap-northeast-1')
    s3.upload_file(local_path, bucket_name, 'raw/sample_data.csv')
    print(f"アップロード完了: s3://{bucket_name}/raw/sample_data.csv")
    print(f"データ形状: {df.shape}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--n-samples', type=int, default=1000)
    args = parser.parse_args()
    generate_and_upload(args.bucket, args.n_samples)
