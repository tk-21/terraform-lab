#!/bin/bash
# テスト用CSVをS3入力バケットにアップロード
set -euo pipefail

INPUT_BUCKET=$(cd "$(dirname "$0")/../terraform/environments/dev" && terraform output -raw input_bucket_name)

cat << 'EOF' > /tmp/test_input.csv
id,title,description,category
1,AWS Step Functions入門,サーバーレスワークフローを構築する,tech
2,Amazon Bedrockの使い方,生成AI APIを呼び出す方法,ai
3,ECS Fargateでコンテナを動かす,サーバーレスコンテナ実行環境,infra
4,,空のタイトル行（クレンジング対象）,misc
5,Terraform入門  ,前後に空白あり（正規化対象）  ,iac
EOF

aws s3 cp /tmp/test_input.csv "s3://$INPUT_BUCKET/input/test_$(date +%Y%m%d_%H%M%S).csv"
echo "アップロード完了: s3://$INPUT_BUCKET/input/"
