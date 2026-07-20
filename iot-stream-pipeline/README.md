# IoT Stream Pipeline ハンズオン

Kinesis → Lambda → DynamoDB → API Gateway をTerraformで構築する、
コンテナLambdaを使ったリアルタイムストリーム処理パイプラインです。

---

## このハンズオンで得られること

### 実装スキル

| スキル | 具体的な内容 |
|---|---|
| **Terraformモジュール設計** | 5つのモジュール (Kinesis/DynamoDB/ECR/Lambda/API GW) を依存関係を意識して分割する経験 |
| **コンテナLambda** | Dockerfileの作成、ECRへのarm64イメージのクロスビルド&プッシュ、LambdaへのECRイメージ紐付け |
| **Kinesisストリーム処理** | ESM (Event Source Mapping) の設定、バッチウィンドウ、`bisect_on_function_error` による部分リトライ |
| **DynamoDB設計** | パーティションキー/ソートキーの選定理由、PAY_PER_REQUEST vs Provisioned、TTLによる自動削除 |
| **API Gateway REST API** | Lambda Proxy統合、ステージ/デプロイメントの概念、アクセスログのCloudWatch連携 |
| **IAM最小権限設計** | Lambdaごとにロールを分離し、必要なアクション・リソースARNのみを許可する実装 |

### 「なぜそうするか」を説明できるようになること

このハンズオンはコードを写経するだけでなく、設計判断の理由まで身につけることを目標としています。
完了後には以下を自分の言葉で15分説明できる状態を目指してください。

- **KinesisとSQSの違い**と、このパイプラインでKinesisを選んだ理由
- **LambdaコンテナとZIPデプロイの使い分け**とトレードオフ
- **`bisect_on_function_error` がない場合**に何が起きるか
- **DynamoDBのキー設計**とアクセスパターンの関係
- **API GatewayのLambda Proxy統合**の仕組みと非プロキシ統合との違い

### 面接で語れる数値

E2Eテスト完了後、以下の数値を自分の実測値として記録してください。

- [ ] Kinesis → DynamoDB 書き込みレイテンシ: **___ms**
- [ ] API Gateway レスポンスタイム: **___ms**
- [ ] シミュレータ実行中の成功率: **___%**

---

## アーキテクチャ概要

```
[センサーシミュレータ (Python)]
        │ PutRecord (device_id をPartitionKey)
        ▼
[Kinesis Data Streams]  ON_DEMAND / 24h保持
        │ ESM: batch=100件 or 10秒
        ▼
[Lambda: processor]  arm64 / ECRコンテナ / bisect=true
        │ PutItem (Decimal型, TTL=72h)
        ▼
[DynamoDB]  PAY_PER_REQUEST / PK=device_id / SK=timestamp
        ▲
        │ Query (ScanIndexForward=False)
[Lambda: reader]  arm64 / ECRコンテナ
        ▲
        │ Proxy統合
[API Gateway REST]  GET /sensors/{device_id}
        ▲
[クライアント (curl)]
```

詳細な設計解説は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

---

## 前提条件

### 必須ツール

```bash
# バージョン確認コマンド
terraform version        # >= 1.6.0
aws --version            # AWS CLI v2
docker info              # Docker Daemon が起動していること
jq --version             # JSONパース用
```

### AWS 権限

実行するIAMユーザー/ロールに以下のサービスへのアクセス権が必要です。

- Kinesis Data Streams (Create/Delete/Read)
- DynamoDB (CreateTable/DeleteTable/Read/Write)
- ECR (CreateRepository/DeleteRepository/PutImage)
- Lambda (CreateFunction/DeleteFunction/UpdateFunction)
- API Gateway (Create/Delete/Deploy)
- IAM (CreateRole/DeleteRole/PutRolePolicy)
- CloudWatch Logs (CreateLogGroup/PutRetentionPolicy)

```bash
# 現在の認証情報を確認
aws sts get-caller-identity
```

### Docker Buildx の確認

arm64イメージのクロスビルドに `buildx` を使用します。

```bash
docker buildx version
# インストールされていない場合 (Docker Desktop は標準搭載)
docker buildx install
```

---

## ディレクトリ構成

```
iot-stream-pipeline/
├── terraform/              # Terraformコード
│   ├── main.tf             # ルートモジュール
│   ├── variables.tf        # 入力変数
│   ├── outputs.tf          # 出力値
│   └── modules/
│       ├── kinesis/        # Kinesisストリーム
│       ├── dynamodb/       # DynamoDBテーブル
│       ├── ecr/            # ECRリポジトリ
│       ├── lambda/         # Lambda × 2 + ESM + IAM
│       └── apigateway/     # REST API + ステージ
├── lambda/
│   ├── processor/          # Kinesis→DynamoDB書き込みLambda
│   └── reader/             # API GW→DynamoDB読み取りLambda
├── simulator/
│   └── sensor_simulator.py # IoTセンサーシミュレータ
├── scripts/
│   ├── push_images.sh      # ECRへのDockerイメージプッシュ
│   └── e2e_test.sh         # パイプライン全体のE2Eテスト
└── docs/
    └── adr/
        └── ADR-001-container-lambda.md
```

---

## Phase 1 — 基盤インフラ構築

**構築するリソース:** Kinesis Data Streams / DynamoDB / ECR

### 手順

```bash
# プロジェクトルートにいることを確認
pwd
# → /path/to/iot-stream-pipeline

# Terraform初期化
cd terraform
terraform init
```

期待する出力:
```
Initializing modules...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
Terraform has been successfully initialized!
```

```bash
# 差分確認
terraform plan
```

作成されるリソースを確認します（`+` が付いているものが新規作成）:
- `aws_kinesis_stream.sensor` — ストリーム (ON_DEMAND)
- `aws_dynamodb_table.sensor_data` — テーブル (PAY_PER_REQUEST, TTL有効)
- `aws_ecr_repository.processor` / `.reader` — コンテナリポジトリ × 2
- `aws_ecr_lifecycle_policy.*` — 最新1件保持ポリシー

```bash
# デプロイ実行 (ユーザーが実行)
terraform apply

# 出力値をファイルに保存 (Phase2で使用)
terraform output -json > ../phase1_outputs.json
cat ../phase1_outputs.json
```

### 動作確認

```bash
# Kinesisがアクティブか
aws kinesis describe-stream-summary \
  --stream-name iot-pipeline-stream \
  --query 'StreamDescriptionSummary.StreamStatus'
# → "ACTIVE"

# DynamoDBテーブルが存在するか
aws dynamodb describe-table \
  --table-name iot-pipeline-table \
  --query 'Table.{Status:TableStatus,BillingMode:BillingModeSummary.BillingMode}'
# → {"Status": "ACTIVE", "BillingMode": "PAY_PER_REQUEST"}

# ECRリポジトリが2つ作成されているか
aws ecr describe-repositories \
  --query 'repositories[*].repositoryName'
# → ["iot-pipeline-processor", "iot-pipeline-reader"]
```

### ここで確認できること

- Terraformがモジュール単位でリソースを管理する構造
- Kinesisの `ON_DEMAND` モードとシャード自動スケール
- DynamoDBの `device_id` (PK) + `timestamp` (SK) の複合キー設計
- ECRライフサイクルポリシーが最新イメージ1件のみ保持する理由

---

## Phase 2 — Lambdaコンテナ構築

**構築するリソース:** Lambda (processor/reader) / ESM / IAMロール

### 前提確認

```bash
# Phase1の出力ファイルが存在するか
ls -la phase1_outputs.json

# Docker Daemonが起動しているか
docker info > /dev/null && echo "OK"
```

### Step 1: ECRへDockerイメージをプッシュ

```bash
# プロジェクトルートに戻る
cd ..   # terraform/ から戻る場合

# スクリプトに実行権限を付与
chmod +x scripts/push_images.sh

# arm64イメージをビルドしてECRにプッシュ
./scripts/push_images.sh
```

期待する出力:
```
=== ECRログイン ===
Login Succeeded

=== processorイメージビルド & プッシュ ===
[+] Building 45.2s (8/8) FINISHED
 => [internal] load build definition from Dockerfile
 => => transferring dockerfile: 245B
 ...
 => pushing manifest for 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/iot-pipeline-processor:latest

=== readerイメージビルド & プッシュ ===
[+] Building 12.3s (8/8) FINISHED   ← キャッシュが効いて高速
 ...

=== プッシュ完了 ===
processor: 123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/iot-pipeline-processor:latest
reader:    123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/iot-pipeline-reader:latest
image URIを phase2_image_uris.env に保存しました
```

> **Note: なぜ `--platform linux/arm64` を指定するか**
> ローカルPCがx86_64 (Intel/AMD) の場合でも、Lambda実行環境はarm64 (Graviton2) です。
> `docker buildx` のクロスビルド機能でアーキテクチャを指定してビルドします。

### Step 2: LambdaとESMをデプロイ

```bash
# image URIを環境変数に読み込む
source phase2_image_uris.env

# 確認
echo "Processor: ${PROCESSOR_IMAGE_URI}"
echo "Reader:    ${READER_IMAGE_URI}"

# Lambdaリソースをデプロイ (ユーザーが実行)
cd terraform
terraform apply \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}"

terraform output -json > ../phase2_outputs.json
```

### 動作確認

```bash
# Lambda関数が存在し、arm64で動いているか
aws lambda get-function \
  --function-name iot-pipeline-processor \
  --query 'Configuration.{State:State,Arch:Architectures[0],ImageUri:Code.ImageUri}'
# → {"State": "Active", "Arch": "arm64", "ImageUri": "..."}

# Kinesis ESMが有効になっているか
aws lambda list-event-source-mappings \
  --function-name iot-pipeline-processor \
  --query 'EventSourceMappings[0].{State:State,BatchSize:BatchSize,Bisect:BisectBatchOnFunctionError}'
# → {"State": "Enabled", "BatchSize": 100, "Bisect": true}
```

### テストレコードを1件送信して動作確認

```bash
# Kinesisにテストデータを送信
aws kinesis put-record \
  --stream-name iot-pipeline-stream \
  --partition-key "device-001" \
  --data "$(echo '{"device_id":"device-001","temperature":25.3,"humidity":60.1,"status":"normal","timestamp":"2024-01-01T00:00:00+00:00"}' | base64)"

# 30秒待機 (Lambdaがバッチを処理するまでの時間)
echo "30秒待機中..."
sleep 30

# DynamoDBに書き込まれているか確認
aws dynamodb get-item \
  --table-name iot-pipeline-table \
  --key '{"device_id":{"S":"device-001"},"timestamp":{"S":"2024-01-01T00:00:00+00:00"}}' \
  --query 'Item'
```

期待する出力:
```json
{
  "device_id": {"S": "device-001"},
  "timestamp": {"S": "2024-01-01T00:00:00+00:00"},
  "temperature": {"N": "25.3"},
  "humidity": {"N": "60.1"},
  "status": {"S": "normal"},
  "expires_at": {"N": "1704412800"}
}
```

### ここで確認できること

- `phase2_image_uris.env` を経由してimage URIをTerraform外から渡す設計の理由
- `bisect_batch_on_function_error = true` の効果（1件の不正データでバッチ全体が止まらない）
- `batch_size=100` + `maximum_batching_window_in_seconds=10` のバッファリング動作
- processorとreaderでIAMロールを分離し、最小権限を実装している構造

---

## Phase 3 — API Gateway構築

**構築するリソース:** REST API / Lambda Proxy統合 / CloudWatchアクセスログ

### デプロイ

```bash
# プロジェクトルートにいることを確認
cd ..   # terraform/ から戻る場合

# image URIを再読み込み (セッションが切れている場合)
source phase2_image_uris.env

cd terraform
terraform apply \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}"

# APIエンドポイントを保存
terraform output -json > ../phase3_outputs.json
API_ENDPOINT=$(jq -r '.api_endpoint.value' ../phase3_outputs.json)
echo "API エンドポイント: ${API_ENDPOINT}"
```

### 動作確認

```bash
API_ENDPOINT=$(jq -r '.api_endpoint.value' phase3_outputs.json)

# データが取得できるか (Phase2でテストデータを送信済みの場合)
curl -s "${API_ENDPOINT}/device-001" | jq .
```

期待するレスポンス:
```json
{
  "device_id": "device-001",
  "count": 1,
  "items": [
    {
      "device_id": "device-001",
      "timestamp": "2024-01-01T00:00:00+00:00",
      "temperature": 25.3,
      "humidity": 60.1,
      "status": "normal",
      "expires_at": 1704412800
    }
  ]
}
```

```bash
# limit パラメータで件数を絞る
curl -s "${API_ENDPOINT}/device-001?limit=3" | jq .

# 存在しないdevice_idは空のitemsが返る (エラーではない)
curl -s "${API_ENDPOINT}/device-999" | jq .
# → {"device_id": "device-999", "count": 0, "items": []}

# HTTP ステータスコードも確認
curl -s -o /dev/null -w "%{http_code}" "${API_ENDPOINT}/device-001"
# → 200
```

### CloudWatch アクセスログの確認

```bash
# APIへのリクエストログを確認
aws logs tail /aws/apigateway/iot-pipeline --since 5m --format short
```

期待する出力 (JSON形式のアクセスログ):
```json
{
  "requestId": "abc123",
  "ip": "203.0.113.1",
  "requestTime": "01/Jan/2024:00:00:00 +0000",
  "httpMethod": "GET",
  "resourcePath": "/sensors/{device_id}",
  "status": "200",
  "responseLength": "245",
  "integrationLatency": "87"
}
```

### ここで確認できること

- `integration_http_method = "POST"` がなぜ必要か（Lambda Invoke APIの仕様）
- `triggers = { redeployment = sha1(...) }` でTerraformが変更を検知してデプロイする仕組み
- Lambda Proxy統合で `statusCode` / `headers` / `body` をLambda側で制御する構造

---

## Phase 4 — E2Eテスト & シミュレータ

### Python環境のセットアップ

```bash
# プロジェクトルートで
python3 -m venv .venv
source .venv/bin/activate
pip install boto3

# 確認
python3 -c "import boto3; print('OK')"
```

### センサーシミュレータの実行

5台のデバイスが2秒おきに120秒間データを送信します（合計約300件）。

```bash
# バックグラウンドで実行
python3 simulator/sensor_simulator.py &
SIMULATOR_PID=$!
echo "シミュレータ PID: ${SIMULATOR_PID}"
```

期待する出力（10秒ごとに進捗表示）:
```
シミュレーション開始: 5デバイス × 120秒
ストリーム: iot-pipeline-stream
--------------------------------------------------
進捗: 成功=25, 失敗=0, 成功率=100.0%
進捗: 成功=50, 失敗=0, 成功率=100.0%
進捗: 成功=75, 失敗=2, 成功率=97.4%   ← 異常値(5%)がエラー扱いになる場合あり
...
--------------------------------------------------
完了: 成功=295, 失敗=5
```

### E2Eテストの実行

シミュレータ開始後30秒でデータがDynamoDBに届いているため、この時点でE2Eテストを実行します。

```bash
# 30秒待機
sleep 30

# E2Eテスト実行
chmod +x scripts/e2e_test.sh
./scripts/e2e_test.sh
```

期待する出力:
```
==============================
 IoT Stream Pipeline E2Eテスト
==============================

--- Step 1: Kinesisにテストレコードを送信 ---
49615...（シーケンス番号）
送信完了

--- Step 2: DynamoDB書き込み確認 (最大60秒待機) ---
待機中... 2秒経過
待機中... 4秒経過
✅ DynamoDB書き込み確認: 8234ms (Kinesis送信からの経過時間)

--- Step 3: API Gateway経由でデータ取得 ---
✅ API応答: HTTP 200, 取得件数=10, レイテンシ=143ms
{
  "device_id": "e2e-test-device",
  "count": 1,
  "items": [...]
}

==============================
 E2Eテスト結果サマリ
==============================
Kinesis → DynamoDB レイテンシ: 8234ms
API Gateway レイテンシ:         143ms
テスト結果: ✅ 全項目PASS
```

```bash
# シミュレータの終了を待つ
wait ${SIMULATOR_PID}
echo "全テスト完了"
```

### CloudWatch メトリクスで処理状況を確認

```bash
# Lambda処理エラー率 (過去10分間)
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=iot-pipeline-processor \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'Datapoints[*].{Time:Timestamp,Errors:Sum}' \
  --output table

# Kinesis受信レコード数
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=iot-pipeline-stream \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'Datapoints[*].{Time:Timestamp,Records:Sum}' \
  --output table
```

---

## クリーンアップ（必ず実施）

**テスト完了後は必ず全リソースを削除してください。放置するとコストが発生し続けます。**

```bash
# image URIを再読み込み
source phase2_image_uris.env

# 全Terraformリソースを削除 (ユーザーが実行)
cd terraform
terraform destroy \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}"
```

`Destroy complete! Resources: XX destroyed.` と表示されれば完了です。

```bash
# ECRイメージも削除 (Terraform管理外のイメージが残る場合)
aws ecr batch-delete-image \
  --repository-name iot-pipeline-processor \
  --image-ids imageTag=latest 2>/dev/null || true

aws ecr batch-delete-image \
  --repository-name iot-pipeline-reader \
  --image-ids imageTag=latest 2>/dev/null || true

echo "クリーンアップ完了"
```

### 削除確認

```bash
# Kinesisストリームが存在しないことを確認
aws kinesis describe-stream-summary \
  --stream-name iot-pipeline-stream 2>&1 | grep -q "ResourceNotFoundException" \
  && echo "✅ Kinesis削除確認" || echo "❌ Kinesisが残っています"

# DynamoDBテーブルが存在しないことを確認
aws dynamodb describe-table \
  --table-name iot-pipeline-table 2>&1 | grep -q "ResourceNotFoundException" \
  && echo "✅ DynamoDB削除確認" || echo "❌ DynamoDBが残っています"
```

---

## トラブルシューティング

### `terraform init` が失敗する

```bash
# プロバイダーのキャッシュをクリアして再試行
rm -rf .terraform .terraform.lock.hcl
terraform init
```

### ECRへのプッシュで `no basic auth credentials` エラー

```bash
# ECR認証を再実行
ACCOUNT_ID=$(jq -r '.aws_account_id.value' ../phase1_outputs.json)
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.ap-northeast-1.amazonaws.com"
```

### Lambda関数が `"State": "Failed"` になる

コンテナイメージのプラットフォームが一致していない可能性があります。

```bash
# イメージのアーキテクチャを確認
docker inspect \
  $(jq -r '.ecr_processor_url.value' phase1_outputs.json):latest \
  --format '{{.Architecture}}'
# → "arm64" であることを確認

# arm64でないなら再ビルド
./scripts/push_images.sh
```

### DynamoDBにデータが書き込まれない

```bash
# Lambdaのログを確認
aws logs tail /aws/lambda/iot-pipeline-processor --since 5m --format short

# ESMの状態を確認
aws lambda list-event-source-mappings \
  --function-name iot-pipeline-processor \
  --query 'EventSourceMappings[0].{State:State,StateTransitionReason:StateTransitionReason}'
```

### `source phase2_image_uris.env` でコマンドが見つからない

```bash
# ファイルの存在確認
ls -la phase2_image_uris.env

# 存在しない場合はスクリプトを再実行
./scripts/push_images.sh
```

### E2Eテストが `jq: error` で失敗する

```bash
# phase3_outputs.json が存在するか確認
ls -la phase3_outputs.json

# 存在しない場合はPhase3のoutputを再取得
cd terraform
terraform output -json > ../phase3_outputs.json
```

---

## 参考資料

- [ARCHITECTURE.md](./ARCHITECTURE.md) — 詳細な設計解説・データフロー・面接トーキングポイント
- [docs/adr/ADR-001-container-lambda.md](./docs/adr/ADR-001-container-lambda.md) — LambdaコンテナとZIPの選択理由 (自分の言葉で記述)
- [AWS公式: Kinesis ESM設定](https://docs.aws.amazon.com/lambda/latest/dg/with-kinesis.html)
- [AWS公式: Lambda コンテナイメージ](https://docs.aws.amazon.com/lambda/latest/dg/images-create.html)
