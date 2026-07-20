# Order Pipeline Lab

ECサイト注文処理を模した、**障害耐性重視の非同期処理パイプライン**。  
SQS → Step Functions → Lambda / ECS Fargate の構成を、Terraform で一から構築するハンズオンです。

---

## このハンズオンで得られること

### 技術スキル

| カテゴリ | 習得内容 |
|---|---|
| **非同期アーキテクチャ** | SQS キューイング・visibility timeout の設計・DLQ によるメッセージ隔離 |
| **オーケストレーション** | Step Functions による複数サービスの状態管理・リトライ・エラーハンドリング |
| **障害耐性パターン** | Saga パターン・補償トランザクション・べき等性設計 |
| **コンテナ実行** | ECS Fargate (FARGATE_SPOT) による Docker コンテナのサーバーレス実行 |
| **IaC** | Terraform モジュール設計・依存関係管理・outputs によるモジュール間連携 |
| **可観測性** | CloudWatch ダッシュボード・カスタムメトリクス・X-Ray 分散トレーシング |
| **コスト最適化** | NAT Gateway 不使用・ARM64 (Graviton2)・Spot 活用で月額 ~$5 を実現 |
| **セキュリティ** | VPC プライベートサブネット・IAM 最小権限・非 root コンテナ実行 |

### 面接で語れる具体的な数字（ハンズオン完了後）

- Step Functions の成功率・失敗率（chaos-test.sh 実行結果）
- DLQ への到達件数と補償処理の実行数
- ECS Fargate の平均起動・実行時間
- X-Ray トレースから計測した E2E 処理時間

---

## アーキテクチャ概要

```
クライアント
    │
    ▼
SQS: orders-queue ────(3回失敗)────→ SQS: orders-dlq
    │ (batch=1)                              │ (batch=5)
    ▼                                        ▼
Lambda: sfn-trigger              Lambda: dlq-reprocessor
    │                              (補償処理 → CANCELLED_BY_DLQ)
    ▼ StartExecution
Step Functions State Machine
    ├─ ① Initialize          → DynamoDB: RECEIVED
    ├─ ② CheckInventory      → Lambda: inventory-check
    ├─ ③ IsInventoryOk       → [OK] / [NG → FAILED]
    ├─ ④ ProcessPayment      → ECS Fargate: payment-processor
    ├─ ⑤ NotifySuccess       → Lambda: notification → COMPLETED
    └─ ⑥ NotifyFailure       → Lambda: notification → FAILED
                │
                ▼
         DynamoDB: orders テーブル
```

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

---

## 前提条件

### 必要なツール

以下をインストールして、バージョンを確認してください。

```bash
# Terraform
terraform --version
# → Terraform v1.5.0 以上

# AWS CLI v2
aws --version
# → aws-cli/2.x.x

# Docker (arm64 ビルドに buildx が必要)
docker --version
docker buildx version

# jq (テストスクリプトの JSON 整形に使用)
jq --version
```

### AWS 認証

```bash
# 認証情報が設定されていることを確認
aws sts get-caller-identity
```

以下のような出力が得られれば OK です。

```json
{
    "UserId": "AIDA...",
    "Account": "123456789012",
    "Arn": "arn:aws:iam::123456789012:user/your-username"
}
```

### 必要な IAM 権限

ハンズオン実行ユーザーには以下のサービスへの権限が必要です。

- VPC / Subnet / Security Group / VPC Endpoint
- SQS / DynamoDB / Lambda / ECS / ECR
- Step Functions / IAM / CloudWatch / X-Ray

---

## ハンズオン手順

### Step 0: リポジトリのクローン

```bash
git clone <your-repo-url>
cd terraform-lab/order-pipeline-lab
```

ディレクトリ構成を確認します。

```
order-pipeline-lab/
├── terraform/           # インフラ定義
│   └── modules/
│       ├── networking/  # VPC・サブネット・VPC Endpoint
│       ├── sqs/         # 注文キュー・DLQ
│       ├── lambda/      # Lambda 関数群
│       ├── ecs/         # ECS クラスター・ECR・タスク定義
│       ├── step_functions/ # ステートマシン・sfn-trigger
│       └── monitoring/  # CloudWatch ダッシュボード・アラーム
├── lambda/              # Lambda ソースコード (Python)
│   ├── inventory-check/
│   ├── notification/
│   └── dlq-reprocessor/
├── ecs/
│   └── payment-processor/ # Docker コンテナ (決済処理)
├── step_functions/
│   └── order-pipeline.asl.json
├── scripts/             # テスト・運用スクリプト
└── docs/adr/            # 設計判断の記録
```

---

### Step 1: Terraform 初期化

```bash
cd terraform
terraform init
```

**確認すべき出力:**

```
Initializing modules...
- ecs in modules/ecs
- lambda in modules/lambda
- monitoring in modules/monitoring
- networking in modules/networking
- sqs in modules/sqs
- step_functions in modules/step_functions

Terraform has been successfully initialized!
```

---

### Step 2: デプロイ内容の確認

```bash
terraform plan
```

作成されるリソースの数を確認します（目安: 70〜90 リソース）。

```
Plan: XX to add, 0 to change, 0 to destroy.
```

> **コストの目安**  
> このハンズオンで作成するリソースは、常時稼働させても月額 ~$5 です。
> テスト後に `scripts/cleanup.sh` を実行すれば費用はほぼゼロになります。

---

### Step 3: インフラのデプロイ

```bash
terraform apply
```

確認プロンプトが表示されたら `yes` と入力します。

```
Do you want to perform these actions?
  Terraform will perform the actions described above.
  Only 'yes' will be accepted to approve.

  Enter a value: yes
```

完了まで **5〜10分** 程度かかります。

**完了後の出力例:**

```
Apply complete! Resources: XX added, 0 changed, 0 destroyed.

Outputs:

dashboard_url         = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/..."
dynamodb_table_name   = "order-pipeline-orders"
ecr_repository_url    = "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/order-pipeline/payment-processor"
ecs_cluster_name      = "order-pipeline-cluster"
orders_dlq_url        = "https://sqs.ap-northeast-1.amazonaws.com/..."
orders_queue_url      = "https://sqs.ap-northeast-1.amazonaws.com/..."
state_machine_arn     = "arn:aws:states:ap-northeast-1:...:stateMachine:order-pipeline-order-sfn"
state_machine_name    = "order-pipeline-order-sfn"
```

> **一時変数として保存しておくと便利です:**
> ```bash
> QUEUE_URL=$(terraform output -raw orders_queue_url)
> STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)
> ECR_URL=$(terraform output -raw ecr_repository_url)
> ```

---

### Step 4: Docker イメージのビルドと ECR へのプッシュ

ECS Fargate で動く決済処理コンテナをビルドして、ECR に登録します。

```bash
# terraform ディレクトリを出てプロジェクトルートへ
cd ..

# ビルド & プッシュ (arm64)
bash scripts/build-and-push.sh
```

**スクリプトが行うこと:**

1. AWS アカウント ID を取得して ECR URL を構築
2. `aws ecr get-login-password` で ECR 認証
3. `docker buildx build --platform linux/arm64` で ARM64 イメージをビルド
4. ECR へ `latest` タグと git SHA タグで push

**完了の確認:**

```bash
aws ecr describe-images \
  --repository-name order-pipeline/payment-processor \
  --region ap-northeast-1 \
  --query 'imageDetails[*].imageTags'
```

```json
[["latest", "abc1234"]]
```

> **arm64 ビルドに関する注意**  
> x86_64 (Intel/AMD) マシンで arm64 イメージをビルドするには、
> Docker Desktop の「Use Rosetta for x86/amd64 emulation」を有効にするか、
> `docker buildx create --use` でマルチプラットフォームビルダーを作成してください。

---

### Step 5: E2E 動作確認（正常ケース）

注文を1件投入して、パイプライン全体が正常動作することを確認します。

#### 5-1. 注文を投入する

```bash
ORDER_ID="test-$(date +%s)"

aws sqs send-message \
  --queue-url $(cd terraform && terraform output -raw orders_queue_url) \
  --message-body "{
    \"order_id\": \"${ORDER_ID}\",
    \"amount\": 3000,
    \"items\": [{\"sku\": \"X001\", \"qty\": 1}]
  }" \
  --region ap-northeast-1

echo "投入完了: ${ORDER_ID}"
```

#### 5-2. Step Functions の実行状況を確認する

AWS コンソールで確認する場合:

```bash
# ステートマシンの URL を表示
echo "https://ap-northeast-1.console.aws.amazon.com/states/home#/statemachines"
```

CLI で確認する場合:

```bash
# 最新の実行結果を表示
aws stepfunctions list-executions \
  --state-machine-arn $(cd terraform && terraform output -raw state_machine_arn) \
  --region ap-northeast-1 \
  --max-results 5 \
  | jq -r '.executions[] | "\(.status)\t\(.name)"'
```

```
RUNNING    order-test-1705720000
```

#### 5-3. 処理完了を待って DynamoDB を確認する（30秒後）

```bash
sleep 30

aws dynamodb get-item \
  --table-name order-pipeline-orders \
  --key "{\"order_id\": {\"S\": \"${ORDER_ID}\"}}" \
  --region ap-northeast-1 \
  | jq '{
      status: .Item.status.S,
      amount: .Item.amount.N,
      created_at: .Item.created_at.S,
      completed_at: .Item.completed_at.S
    }'
```

**期待する出力:**

```json
{
  "status": "COMPLETED",
  "amount": "3000",
  "created_at": "2024-01-20T10:00:00.000000Z",
  "completed_at": "2024-01-20T10:00:22.345678Z"
}
```

> `status: "COMPLETED"` が確認できればパイプライン全体が正常に動作しています。

---

### Step 6: CloudWatch ダッシュボードで可視化を確認する

```bash
# ダッシュボードの URL を表示
cd terraform && terraform output -raw dashboard_url
```

表示された URL をブラウザで開くと、以下のウィジェットが確認できます。

| ウィジェット | 確認ポイント |
|---|---|
| Step Functions 実行結果 | `ExecutionsSucceeded` が増加していること |
| SQS メッセージ数 | `NumberOfMessagesSent` が 1 増加し、`NumberOfMessagesDeleted` も 1 増加していること |
| Lambda エラー率 | Errors が 0 であること |
| カスタムメトリクス | `InventoryCheckSuccess` / `NotificationSent` が増加していること |

---

### Step 7: X-Ray でトレースを確認する

```bash
echo "https://ap-northeast-1.console.aws.amazon.com/xray/home#/traces"
```

Service Map では以下のフローが可視化されます。

```
sfn-trigger → order-pipeline-order-sfn → inventory-check
                                       → payment-processor (ECS)
                                       → notification
                                       → DynamoDB
```

各コンポーネントの**レイテンシ**と**エラー率**が一目で確認できます。

---

### Step 8: 障害耐性テスト（chaos-test.sh）

20件の注文を連続投入し、DLQ・リトライ・成功率を数値で確認します。

```bash
cd ..  # プロジェクトルートへ
bash scripts/chaos-test.sh
```

**スクリプトの動作:**

1. 注文20件をランダムな金額・SKU で連続投入（0.5秒間隔）
2. 30秒待機（処理が完了するまで）
3. Step Functions の実行結果を集計（ステータス別件数）
4. DLQ のメッセージ数を確認
5. DynamoDB のステータス別件数を集計

**出力例:**

```
=== 障害耐性テスト開始 ===
注文 20件を連続投入します...
  投入: chaos-1705720001-1 (amount=7432)
  投入: chaos-1705720001-2 (amount=2891)
  ...（省略）...

=== 投入完了: 20件 ===
30秒後に結果を集計します...

=== Step Functions 実行結果 ===
SUCCEEDED: 17件
FAILED: 3件

=== DLQ メッセージ数 ===
0 件が DLQ に到達

=== DynamoDB ステータス集計 ===
COMPLETED: 17件
FAILED: 3件

=== テスト完了 ===
```

> **FAILED が発生する理由**  
> `inventory-check` が10%の確率で在庫切れをシミュレートするため、
> 20件投入すると平均2件が `INVENTORY_FAILED` → `FAILED` になります。
> これは正常な動作です。

---

### Step 9: DLQ 動作テスト（test-dlq.sh）

意図的に壊れたメッセージ（`order_id` なし）を投入し、DLQ への転送と補償処理を確認します。

```bash
bash scripts/test-dlq.sh
```

**スクリプトの動作:**

1. `order_id` を含まない不正な JSON を3件投入
2. `sfn-trigger` Lambda が `order_id` 取り出しでエラー
3. SQS が `visibility_timeout` (300秒) 経過後にメッセージを再可視化
4. 3回受信失敗 → `maxReceiveCount` 超過 → DLQ へ転送
5. `dlq-reprocessor` Lambda が DLQ を処理

**DLQ 確認コマンド（約3分後に実行）:**

```bash
DLQ_URL=$(cd terraform && terraform output -raw orders_dlq_url)

aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  --region ap-northeast-1 \
  | jq -r '"DLQ メッセージ数: " + .Attributes.ApproximateNumberOfMessages'
```

> **注意**: SQS の `visibility_timeout` が 300秒のため、DLQ に到達するまで  
> 最大 **15分**（300秒 × 3回）かかります。テスト用に短縮したい場合は  
> `terraform/modules/sqs/main.tf` の `visibility_timeout_seconds` を一時的に小さくしてください。

---

### Step 10: テスト結果の記録

ハンズオン完了後、以下に結果を記録しておくと面接で具体的な数字として使えます。

```bash
# テンプレートを開く
cat docs/test-results.md
```

`docs/test-results.md` を編集して、実際の数値を埋めてください。

```markdown
## E2E テスト結果 (20件投入)
- 成功: 17件 (85%)
- 在庫不足による失敗: 3件
- DLQ 到達: 0件

## パフォーマンス
- 平均 Step Functions 実行時間: 22秒
- 決済処理 (ECS) 平均時間: 8秒
```

---

### Step 11: リソースの削除（ハンズオン終了時）

**課金を止めるために必ず実行してください。**

```bash
bash scripts/cleanup.sh
```

**スクリプトの動作:**

1. 確認プロンプト（`yes` と入力して続行）
2. ECR イメージを先に削除（残っていると `terraform destroy` が失敗するため）
3. `terraform destroy -auto-approve` を実行

**完了の確認:**

```bash
# すべてのリソースが削除されたことを確認
aws dynamodb list-tables --region ap-northeast-1 | jq '.TableNames | map(select(startswith("order-pipeline")))'
# → []

aws sqs list-queues --queue-name-prefix order-pipeline --region ap-northeast-1
# → (空)
```

---

## トラブルシューティング

### `terraform apply` が ECR で失敗する

```
Error: creating ECR Repository: RepositoryAlreadyExistsException
```

以前のハンズオンの残骸が残っています。先に削除してください。

```bash
aws ecr delete-repository \
  --repository-name order-pipeline/payment-processor \
  --region ap-northeast-1 \
  --force
```

---

### `docker buildx build` が失敗する（arm64 エラー）

```
error: failed to solve: ... exec format error
```

Docker の QEMU エミュレーションを有効にしてください。

```bash
# QEMU セットアップ (Linux)
docker run --privileged --rm tonistiigi/binfmt --install arm64

# ビルダーを作成
docker buildx create --name mybuilder --use
docker buildx inspect --bootstrap
```

---

### Step Functions が `FAILED` になる

Step Functions コンソールで実行の詳細を確認します。

```bash
# 最新の失敗実行を取得
aws stepfunctions list-executions \
  --state-machine-arn $(cd terraform && terraform output -raw state_machine_arn) \
  --status-filter FAILED \
  --region ap-northeast-1 \
  --max-results 1 \
  | jq -r '.executions[0].executionArn'
```

取得した ARN で詳細を確認します。

```bash
aws stepfunctions get-execution-history \
  --execution-arn <上記のARN> \
  --region ap-northeast-1 \
  | jq '.events[] | select(.type | contains("Failed")) | .executionFailedEventDetails // .taskFailedEventDetails'
```

---

### DynamoDB のステータスが `INVENTORY_CHECKING` のまま止まっている

Lambda が VPC Endpoint に到達できていない可能性があります。

```bash
# Lambda のログを確認
aws logs tail /aws/lambda/order-pipeline-inventory-check \
  --region ap-northeast-1 \
  --since 10m \
  --format short
```

---

### `cleanup.sh` で `terraform destroy` が失敗する

ECR にイメージが残っている可能性があります。

```bash
# ECR イメージを手動削除
aws ecr list-images \
  --repository-name order-pipeline/payment-processor \
  --region ap-northeast-1 \
  --query 'imageIds' \
  --output json | \
  xargs -I{} aws ecr batch-delete-image \
    --repository-name order-pipeline/payment-processor \
    --image-ids '{}' \
    --region ap-northeast-1

# 再度 destroy
cd terraform && terraform destroy
```

---

## 参考リソース

| ドキュメント | 内容 |
|---|---|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | アーキテクチャの完全解説・設計判断の詳細 |
| [docs/adr/adr-001-sqs-visibility-timeout.md](./docs/adr/adr-001-sqs-visibility-timeout.md) | visibility_timeout を 300秒にした理由 |
| [docs/adr/adr-002-step-functions-retry.md](./docs/adr/adr-002-step-functions-retry.md) | Retry 戦略と JitterStrategy の設計 |
| [docs/adr/adr-003-dlq-compensation.md](./docs/adr/adr-003-dlq-compensation.md) | Saga パターンと補償トランザクションの設計 |
| [docs/test-results.md](./docs/test-results.md) | テスト結果の記録シート |
