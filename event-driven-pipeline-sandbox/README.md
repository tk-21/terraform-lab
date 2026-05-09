# AWS Event-Driven AI Pipeline Sandbox

## このプロジェクトの目的

**「Lambda を書けばなんとかなる」思考から抜け出す。**

AWS には Lambda を一切使わずにサービス間を繋げる仕組みが多数ある。
このプロジェクトでは、あえて「Lambda を書いてはいけないルール」を2箇所に設け、
サービス直接統合を実際に手を動かして体験する。

| 場所 | 通常のやり方 | このプロジェクトでのやり方 |
|------|------------|------------------------|
| API → キュー | API Gateway → Lambda → SQS | API Gateway → SQS **直接統合**（Lambda ゼロ） |
| ワークフロー → Bedrock / DB / SNS | Step Functions → Lambda → 各サービス | Step Functions **SDK 統合**（Lambda ゼロ） |

Lambda を書く場面を意図的に絞ることで、「どこに Lambda が本当に必要か」を判断できるようになる。

## 技術スタック

| カテゴリ | 採用技術 |
|---------|---------|
| IaC | Terraform >= 1.5.0 / AWS Provider ~> 5.0 |
| クラウド | AWS ap-northeast-1 |
| メッセージング | Amazon SQS（キュー + DLQ）/ Amazon SNS |
| ワークフロー | AWS Step Functions Standard Workflow |
| AI | Amazon Bedrock（Claude 3 Haiku / Sonnet — SDK 統合） |
| ストレージ | DynamoDB（TTL + GSI + Streams） |
| イベント | Amazon EventBridge（ルーティング + スケジュール） |
| API | API Gateway REST（SQS / DynamoDB 直接統合） |
| 認証 | OIDC（アクセスキー禁止） |
| CI/CD | GitHub Actions |
| 言語 | Python 3.12（Lambda） |

---

## アーキテクチャ

```mermaid
graph TB
    Client["Client"]

    subgraph AWS["AWS ap-northeast-1"]
        subgraph API["API Entry Point"]
            APIGW["API Gateway REST\nPOST /jobs → SQS 直接統合\nGET /jobs/:id → DynamoDB 直接統合"]
        end

        subgraph Messaging["Messaging Layer"]
            SQS["SQS Input Queue\n可視性タイムアウト 30s（dev 現行値）"]
            DLQ["SQS Dead Letter Queue\n最大受信 3回"]
            SNS["SNS notifications\njob.completed / job.failed"]
        end

        subgraph VPC["VPC (10.1.0.0/16)"]
            subgraph Private["Private Subnets"]
                Dispatcher["Dispatcher Lambda\nSQS trigger → DynamoDB write\n→ Step Functions start"]
                StreamProc["Stream Processor Lambda\nDynamoDB Streams → metrics"]
                DLQHandler["DLQ Handler / Cleanup Lambda\n① SFN失敗後処理\n② 停滞ジョブ検出（同一 Lambda）"]
            end
            EP["VPC Endpoints\nDynamoDB / states / SNS / logs"]
        end

        subgraph SFN["Step Functions Standard Workflow"]
            Choice["RouteByComplexity\n(Choice State)"]
            Haiku["InvokeHaiku\nBedrock SDK 統合\n（Lambda 不要）"]
            Sonnet["InvokeSonnet\nBedrock SDK 統合\n（Lambda 不要）"]
            Parallel["ParallelFinalize\n(Parallel State)"]
            SaveResult["SaveResult\nDynamoDB SDK 統合"]
            Notify["NotifyCompletion\nSNS SDK 統合"]
            Fail["HandleFailure\nDynamoDB + SNS"]
        end

        subgraph Data["Data Layer"]
            DDB["DynamoDB jobs table\nTTL / GSI / Streams"]
            Metrics["DynamoDB metrics table\nテナント別日次集計"]
        end

        EB["EventBridge\n① SFN FAILED → DLQ Handler\n② rate(1 hour) → Cleanup"]
    end

    Client -->|POST /jobs| APIGW
    Client -->|GET /jobs/:id| APIGW
    APIGW --> SQS
    APIGW --> DDB
    SQS --> Dispatcher
    SQS --> DLQ
    Dispatcher --> DDB
    Dispatcher --> SFN
    Choice --> Haiku
    Choice --> Sonnet
    Haiku --> Parallel
    Sonnet --> Parallel
    Parallel --> SaveResult
    Parallel --> Notify
    SaveResult --> DDB
    Notify --> SNS
    SFN -->|FAILED event| EB
    EB -->|① SFN失敗| DLQHandler
    EB -->|② 毎時スケジュール| DLQHandler
    DDB -->|Streams| StreamProc
    StreamProc --> Metrics
    DLQHandler --> DDB
    DLQHandler --> SNS
```

---

## ハンズオン実行ガイド

この README は情報量が多いため、まずは次の順番で進めると迷いにくいです。

1. ローカル環境と AWS 権限を確認する
2. Terraform バックエンド用の S3 / DynamoDB を作る
3. `environments/dev` で `terraform init` → `plan` を実行する
4. `terraform apply` を自分で実行する
5. `POST /jobs` でジョブ投入し、`GET /jobs/{jobId}` で完了を確認する
6. CloudWatch / Step Functions / DynamoDB を見て内部の流れを確認する

### 所要時間の目安

- 事前準備: 10〜20 分
- `terraform apply`: 5〜10 分
- E2E 動作確認: 10 分
- 全体: 30〜45 分

### このハンズオンで実際に確認すること

- API Gateway が Lambda なしで SQS に直接送信できること
- Dispatcher Lambda が SQS メッセージをジョブに変換すること
- Step Functions が Bedrock / DynamoDB / SNS を Lambda なしで直接呼ぶこと
- DynamoDB Streams と EventBridge が後続処理と障害補完を担うこと

### 最短で進めるためのおすすめルート

時間がない場合は、まずこの順に実行してください。

1. `前提条件`
2. `事前準備`
3. `デプロイ手順`
4. `動作確認`
5. `トラブルシューティング`

---

## 成功の定義

以下がすべて確認できたら、このプロジェクトは完了とみなす。

### インフラ
- [ ] `terraform apply` がエラーなく完了する
- [ ] `terraform output` で API エンドポイントと API Key ID が出力される

### パイプライン疎通（E2E）
- [ ] `POST /jobs` でジョブが投入でき、レスポンスに `job_id` が含まれる
- [ ] 数十秒後に `GET /jobs/{job_id}` を叩くと `"status": "COMPLETED"` と `result`（Bedrock の回答テキスト）が返ってくる
- [ ] `complexity: "light"` のジョブは `model_used: "haiku"`、`"complex"` は `"sonnet"` になっている
- [ ] API Key なしで叩くと `403 Forbidden` が返る（認証が機能している）

### 耐障害性
- [ ] Step Functions が失敗すると（例: Bedrock のスロットリング）、EventBridge 経由で DLQ Handler Lambda が起動し、DynamoDB の `status` が `FAILED` に更新される
- [ ] 停滞した `PENDING` ジョブは 1 時間ごとのスケジュールで自動的に `TIMEOUT` に更新される
- [ ] DLQ にメッセージが溜まったとき、CloudWatch アラームが発火する

### 可観測性
- [ ] CloudWatch ダッシュボードに SQS / Lambda / Step Functions のメトリクスが表示される
- [ ] X-Ray で POST /jobs から Step Functions 完了までのトレースが追える
- [ ] Lambda のログが `/aws/lambda/<function-name>` に出力されている

### CI/CD（GitHub Actions を使う場合）
- [ ] PR を出すと Terraform Plan の結果がコメントに投稿される
- [ ] main にマージすると `terraform apply` が自動実行される

---

## このプロジェクトで何が身につくか

### 1. 「Lambda をいつ使うべきか」の判断軸

このプロジェクトを終えると、以下の問いに答えられるようになる:

> 「API Gateway から SQS にデータを流したいとき、Lambda は本当に必要か？」

**答え: 不要。** API Gateway の AWS 統合 + VTL マッピングテンプレートで直接 SQS に送れる。
Lambda が必要になるのは「リクエストの内容によって動的に処理を分岐させたい」など、**ロジックが発生する場合のみ**。

> 「Step Functions から DynamoDB に書き込みたいとき、Lambda は本当に必要か？」

**答え: 不要。** SDK 統合（`Resource: "arn:aws:states:::dynamodb:updateItem"`）で直接呼べる。
Lambda を介すと、コード管理・デプロイ・IAM ロール・コールドスタートのコストがすべて増える。

---

### 2. 習得できるサービスパターン

#### API Gateway の直接統合（VTL）
- `POST /jobs` のリクエスト JSON を SQS の `SendMessage` 形式に変換するマッピングテンプレート（VTL）を自分で書いた
- `GET /jobs/{jobId}` の結果として DynamoDB の型付き JSON（`{"S": "value"}`）をフラットな JSON に変換した
- Lambda を挟まないため、レイテンシが下がり、障害点も減る

#### Step Functions SDK 統合
- ASL（Amazon States Language）で Bedrock / DynamoDB / SNS を直接呼ぶステートを定義した
- Choice State で `complexity` フィールドを見て Haiku / Sonnet を使い分けた
- Parallel State で DynamoDB 書き込みと SNS 通知を同時に実行した
- Retry / Catch で Bedrock のスロットリングに対応した

#### SQS + DLQ による耐障害設計
- 可視性タイムアウトを Lambda タイムアウトの 6 倍に設定する理由を理解した
- `ReportBatchItemFailures` で、バッチ内の一部メッセージだけ再試行できるようにした
- `maxReceiveCount` を超えたメッセージのみ DLQ に移動する仕組みを理解した

#### DynamoDB Streams + Lambda フィルタリング
- Streams の `MODIFY` イベントかつ `status` が `COMPLETED` / `FAILED` の場合のみ Lambda を起動するフィルタを設定した
- 不要な Lambda 起動を減らすことでコストと処理量を削減できることを体験した

#### EventBridge によるイベントルーティング
- Step Functions の実行ステータス変化（`FAILED` / `TIMED_OUT`）を EventBridge で自動検知した
- `rate(1 hour)` のスケジュールルールで停滞ジョブを定期クリーンアップする仕組みを実装した

#### Terraform モジュール設計
- 8 つのモジュールを依存関係を考慮しながら設計し、モジュール間を output / variable で接続した
- `templatefile()` で Step Functions の ASL JSON に DynamoDB テーブル名・SNS ARN を注入した
- VPC エンドポイント（Gateway / Interface）を使い、Lambda が NAT Gateway を使わず AWS サービスにアクセスできるようにした

---

## モジュール構成

```
event-driven-pipeline-sandbox/
├── environments/dev/          ← 全モジュールの呼び出しと変数
└── modules/
    ├── networking/            ← VPC / サブネット / VPC エンドポイント
    ├── messaging/             ← SQS (input + DLQ) / SNS
    ├── storage/               ← DynamoDB (jobs + metrics, Streams 有効)
    ├── dispatcher/            ← SQS trigger Lambda → Step Functions 起動
    ├── workflow/              ← Step Functions + Bedrock / DynamoDB / SNS SDK 統合
    ├── stream-processor/      ← DynamoDB Streams → メトリクス集計
    ├── event-router/          ← EventBridge ルール + DLQ Handler / Cleanup Lambda
    ├── api-ingestor/          ← API Gateway REST (SQS / DynamoDB 直接統合)
    └── observability/         ← CloudWatch ダッシュボード / アラーム
```

---

## モジュール間依存関係

```
networking
  └──▶ messaging
  └──▶ storage
         └──▶ workflow
                └──▶ dispatcher (SFN ARN を env var で注入)
                └──▶ stream-processor (DynamoDB Streams)
         └──▶ event-router (SFN ARN をルールのフィルタに使用)
         └──▶ api-ingestor
全モジュール ──▶ observability
```

---

## 構築スケジュール

| Week | モジュール | 学ぶこと |
|------|-----------|---------|
| 1 | networking + messaging | SQS / DLQ / SNS の設計、可視性タイムアウト |
| 2 | storage | DynamoDB TTL / GSI / Streams 設定 |
| 3 | dispatcher | SQS event source mapping、Lambda から SFN 起動 |
| 4 | workflow | Step Functions ASL、Bedrock SDK 統合、Parallel State |
| 5 | stream-processor | DynamoDB Streams + Lambda フィルタリング |
| 6 | event-router + api-ingestor | EventBridge パターン、API GW 直接統合 |
| 7 | observability + GitHub Actions CI/CD | CloudWatch、OIDC |

---

## 前提条件

### 0. ローカルワークスペースの準備

このリポジトリでは、作業前に Python の仮想環境を用意しておく前提です。

```bash
# リポジトリルートで実行
cd event-driven-pipeline-sandbox

# .venv を作成
python3 -m venv .venv

# 有効化
source .venv/bin/activate

# 確認
which python
ls .venv
```

期待値:

- `which python` が `.venv/bin/python` を指す
- `.venv` ディレクトリが存在する

補足:

- このプロジェクトは Terraform の `archive_file` で Lambda パッケージを作るため、README 内のハンズオンでは追加の Python パッケージインストールは必須ではありません
- 将来的に `requirements.txt` が追加された場合は `pip install -r requirements.txt` を実行してください

### ローカル環境

| ツール | バージョン | 確認コマンド |
|--------|-----------|------------|
| Terraform | >= 1.5.0 | `terraform -version` |
| AWS CLI | >= 2.x | `aws --version` |
| jq | any | `jq --version` |

### 動作確認しておくと安心なコマンド

```bash
terraform -version
aws --version
jq --version
aws sts get-caller-identity
```

`aws sts get-caller-identity` が成功しない場合は、Terraform 実行前に AWS 認証の設定を見直してください。

### AWS 権限

デプロイに必要な IAM 権限（管理者権限または以下のサービスへの権限）:

- VPC / サブネット / セキュリティグループ / VPC エンドポイント
- SQS / SNS / DynamoDB / Lambda / Step Functions
- API Gateway / EventBridge / CloudWatch / X-Ray
- IAM ロール・ポリシーの作成
- S3（Terraform バックエンド用）

### Amazon Bedrock モデルアクセス

デプロイ前に、マネジメントコンソールで以下のモデルへのアクセスを有効化してください。

1. AWS コンソール → **Amazon Bedrock** → **モデルアクセス**
2. 以下を有効化:
   - `Anthropic / Claude 3 Haiku` （軽量タスク用）
   - `Anthropic / Claude 3.5 Sonnet` （複雑タスク用）
3. リクエスト承認は通常即時〜数分で完了する

```bash
# 有効化されているか確認
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?contains(modelId,'claude-3')].{id:modelId,status:modelLifecycle.status}" \
  --output table
```

---

## 事前準備

### 1. Terraform バックエンド用リソースを作成

このプロジェクトは `environments/dev/backend.tf` で、S3 に tfstate、DynamoDB に state lock を保存します。先にこの 2 つを手動作成しておかないと `terraform init` が失敗します。

```bash
# S3 バケット（tfstate 保存先）
aws s3 mb s3://tfstate-event-driven-pipeline --region ap-northeast-1

# バージョニングを有効化（tfstate の誤削除対策）
aws s3api put-bucket-versioning \
  --bucket tfstate-event-driven-pipeline \
  --versioning-configuration Status=Enabled

# DynamoDB ロックテーブル
aws dynamodb create-table \
  --table-name tfstate-lock-event-pipeline \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1
```

作成後は次も確認してください。

```bash
aws s3 ls s3://tfstate-event-driven-pipeline

aws dynamodb describe-table \
  --table-name tfstate-lock-event-pipeline \
  --region ap-northeast-1 \
  --query "Table.TableStatus"
```

### 2. GitHub Actions 用 OIDC ロールを作成（CI/CD を使う場合）

```bash
# GitHub リポジトリ情報を設定
GITHUB_ORG="your-github-org"
GITHUB_REPO="your-repo-name"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# OIDC プロバイダーを登録（アカウント内に未登録の場合のみ）
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1

# IAM ロール（trust policy）
cat > /tmp/trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name github-actions-terraform \
  --assume-role-policy-document file:///tmp/trust-policy.json

# 権限を付与（本番では最小権限に絞ること）
aws iam attach-role-policy \
  --role-name github-actions-terraform \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

echo "ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/github-actions-terraform"
```

GitHub リポジトリの **Settings → Secrets and variables → Actions** に以下を登録:

| Secret 名 | 値 |
|-----------|---|
| `AWS_ROLE_ARN` | 上で作成したロールの ARN |
| `ALERT_EMAIL` | アラート通知先メールアドレス（省略可） |

> 補足: 現在の Terraform コードでは `alert_email` 変数は定義されていますが、`messaging` モジュールへの受け渡しが未接続のため、この値だけではメール購読は自動作成されません。

---

## デプロイ手順

### ローカルから手動デプロイ

このプロジェクトでは、Terraform の実行は次の流れで進めるのが安全です。

1. `init` でバックエンド接続と provider 取得
2. `fmt` と `validate` で静的チェック
3. `plan` で差分確認
4. `apply` を自分で実行

以降のコマンドは `environments/dev` ディレクトリで実行します。

```bash
# リポジトリのルートから操作
cd event-driven-pipeline-sandbox/environments/dev

# 1. 初期化（バックエンド接続・プロバイダーダウンロード）
terraform init

# 2. フォーマット確認
terraform fmt -check -recursive

# 3. 構文チェック
terraform validate

# 4. 差分確認（owner は自分の名前に変更）
terraform plan -var="owner=your-name"

# alert_email 変数も渡したい場合（現行コードでは通知購読作成には未接続）
terraform plan \
  -var="owner=your-name" \
  -var="alert_email=your@example.com"

# 5. 適用（確認プロンプトが表示される）
terraform apply -var="owner=your-name"

# 所要時間: 約 5〜10 分
```

### `terraform plan` で見るべきポイント

`plan` の出力では、特に次を確認すると理解が深まります。

- `aws_api_gateway_*`: API Gateway の直接統合リソース
- `aws_sqs_queue.*`: input queue と DLQ
- `aws_lambda_function.*`: 3 つの Lambda
- `aws_sfn_state_machine.ai_pipeline`: Step Functions 本体
- `aws_dynamodb_table.*`: `jobs` と `metrics`
- `aws_cloudwatch_dashboard.pipeline`: 監視ダッシュボード

### `terraform apply` 実行後に確認すること

apply 完了後は、そのまま次の 3 つを確認してください。

```bash
terraform output
terraform output api_endpoint
terraform output state_machine_arn
```

期待値:

- `api_endpoint` が出力される
- `api_key_id` が出力される
- `state_machine_arn` が出力される
- エラーなく `Apply complete!` が表示される

> 注意: `terraform apply` はこの README を読んでいる本人が実行してください。

### GitHub Actions による自動デプロイ

- **Pull Request 作成時**: `terraform plan` を実行し、結果を PR コメントに投稿
- **main ブランチへの push 時**: `terraform apply` を自動実行

対象パスが変更された場合のみワークフローが起動します:

```
event-driven-pipeline-sandbox/environments/**
event-driven-pipeline-sandbox/modules/**
event-driven-pipeline-sandbox/.github/workflows/terraform.yml
```

### デプロイ後の出力確認

```bash
# 主要な出力値を確認
terraform output

# 個別に取得
terraform output api_endpoint       # API Gateway URL
terraform output jobs_endpoint      # POST /jobs の完全 URL
terraform output api_key_id         # API Key ID
terraform output state_machine_arn  # Step Functions ARN
terraform output vpc_id             # VPC ID
```

---

## 動作確認

ここからがハンズオン本番です。まず API Key を取得し、軽量ジョブと複雑ジョブを 1 件ずつ流して、最後に内部状態を確認します。

### Step 1: API Key を取得

```bash
cd event-driven-pipeline-sandbox/environments/dev

API_KEY_ID=$(terraform output -raw api_key_id)
API_KEY=$(aws apigateway get-api-key \
  --api-key "${API_KEY_ID}" \
  --include-value \
  --query value \
  --output text)
API_URL=$(terraform output -raw api_endpoint)

echo "API_URL : ${API_URL}"
echo "API_KEY : ${API_KEY}"
```

期待値:

- `API_URL` が `https://...amazonaws.com/v1` の形式で出る
- `API_KEY` が空文字ではない

### Step 2: ジョブを投入（POST /jobs）

```bash
# 軽量タスク（Claude 3 Haiku で処理）
JOB_ID=$(curl -s -X POST "${API_URL}/jobs" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{
    "tenant_id": "tenant-a",
    "prompt": "AWSのStep Functionsについて3行で説明してください。",
    "complexity": "light"
  }' | jq -r '.job_id')

echo "job_id: ${JOB_ID}"
```

期待値:

- `JOB_ID` に UUID 風の文字列が入る
- `POST /jobs` は数秒以内に `200` を返す
- この時点では処理完了を待たず、SQS に受け付けたことだけが保証される

```bash
# 複雑タスク（Claude 3.5 Sonnet で処理）
JOB_ID_COMPLEX=$(curl -s -X POST "${API_URL}/jobs" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{
    "tenant_id": "tenant-b",
    "prompt": "イベント駆動アーキテクチャのメリット・デメリットを詳しく説明し、採用すべきユースケースを挙げてください。",
    "complexity": "complex"
  }' | jq -r '.job_id')

echo "job_id_complex: ${JOB_ID_COMPLEX}"
```

### Step 3: ジョブの状態を確認（GET /jobs/{jobId}）

```bash
# 処理完了まで数秒〜数十秒かかる（Step Functions + Bedrock の実行時間）
curl -s \
  -H "x-api-key: ${API_KEY}" \
  "${API_URL}/jobs/${JOB_ID}" | jq .

# 期待されるレスポンス例（status: COMPLETED）:
# {
#   "job_id":     "abc12345-...",
#   "tenant_id":  "tenant-a",
#   "status":     "COMPLETED",
#   "complexity": "light",
#   "model_used": "haiku",
#   "result":     "Step Functionsは...",
#   "created_at": "2024-01-15T10:00:00+00:00"
# }
```

```bash
# ポーリングスクリプト（完了まで待機）
for i in $(seq 1 20); do
  STATUS=$(curl -s -H "x-api-key: ${API_KEY}" "${API_URL}/jobs/${JOB_ID}" | jq -r '.status')
  echo "[${i}] status: ${STATUS}"
  if [[ "${STATUS}" == "COMPLETED" || "${STATUS}" == "FAILED" || "${STATUS}" == "TIMEOUT" ]]; then
    break
  fi
  sleep 5
done

# 完了後に結果を取得
curl -s -H "x-api-key: ${API_KEY}" "${API_URL}/jobs/${JOB_ID}" | jq -r '.result'
```

### Step 3.5: `light` と `complex` の違いを確認

```bash
curl -s -H "x-api-key: ${API_KEY}" "${API_URL}/jobs/${JOB_ID}" | jq '{job_id,status,complexity,model_used}'
curl -s -H "x-api-key: ${API_KEY}" "${API_URL}/jobs/${JOB_ID_COMPLEX}" | jq '{job_id,status,complexity,model_used}'
```

期待値:

- `complexity: "light"` のジョブは `model_used: "haiku"`
- `complexity: "complex"` のジョブは `model_used: "sonnet"`

### Step 4: Step Functions の実行を確認

```bash
STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)

# 直近の実行一覧
aws stepfunctions list-executions \
  --state-machine-arn "${STATE_MACHINE_ARN}" \
  --max-results 5 \
  --query "executions[*].{name:name,status:status,start:startDate}" \
  --output table

# 特定の実行の詳細（execution_arn は上のコマンドで取得）
aws stepfunctions get-execution-history \
  --execution-arn "<execution_arn>" \
  --query "events[*].{type:type,time:timestamp}" \
  --output table
```

見るべきポイント:

- `ExecutionStarted`
- `TaskStateEntered` / `TaskStateExited`
- `ExecutionSucceeded` または `ExecutionFailed`

`light` ジョブでは `InvokeHaiku`、`complex` ジョブでは `InvokeSonnet` に対応するイベントが見えるはずです。

### Step 5: CloudWatch ダッシュボードで監視

```bash
# ダッシュボードの URL を表示
DASHBOARD=$(terraform output -raw dashboard_name)
REGION="ap-northeast-1"
echo "https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=${DASHBOARD}"
```

ダッシュボードで確認できる項目:
- SQS キューの深さ・スループット
- DLQ のメッセージ数（蓄積したら要調査）
- Step Functions の成功/失敗数と実行時間
- Lambda の呼び出し数・エラー数

### Step 6: 異常系の動作確認

まず理解しておきたいのは、このプロジェクトには「入力不正」と「実行失敗」で挙動の違いがあることです。

- 入力不正: Dispatcher が検知して破棄。DLQ には流れない
- 実行失敗: Step Functions または EventBridge 経由で `FAILED` 更新
- 長時間停滞: scheduled cleanup により `TIMEOUT` 更新

```bash
# 必須フィールドを欠いたリクエスト（Dispatcher Lambda がバリデーションエラー）
curl -s -X POST "${API_URL}/jobs" \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{"tenant_id": "tenant-a"}' | jq .
# → メッセージは SQS に投入されるが、Dispatcher でバリデーションエラー後に静かに破棄される（DLQ には流れない設計）

# Step Functions の失敗は EventBridge → DLQ Handler Lambda でキャッチされ
# DynamoDB のステータスが FAILED に更新される
```

### Step 7: どの AWS サービスが動いたかを振り返る

E2E 実行後は、次の順番で AWS コンソールまたは CLI を見ると理解が深まります。

1. API Gateway: `POST /jobs` / `GET /jobs/{jobId}`
2. SQS: input queue にメッセージが入り、Dispatcher 後に消える
3. Lambda: `dispatcher` が起動する
4. Step Functions: `haiku` または `sonnet` の分岐が実行される
5. DynamoDB: `jobs` テーブルの `status` が変わる
6. DynamoDB Streams: `stream-processor` がメトリクス更新
7. CloudWatch Dashboard: メトリクス全体を俯瞰

---

## クリーンアップ

```bash
cd event-driven-pipeline-sandbox/environments/dev

# 全リソースを削除（課金停止）
terraform destroy -var="owner=your-name"

# 確認プロンプトに "yes" と入力する
# 所要時間: 約 5〜10 分
```

> **注意**: `terraform destroy` は VPC・Lambda・DynamoDB テーブルを含む全リソースを削除します。
> Terraform バックエンドの S3 バケットと DynamoDB テーブルは手動で削除してください。
> `terraform destroy` もユーザー自身で実行してください。

```bash
# バックエンドリソースの手動削除（最後に実行）
aws s3 rb s3://tfstate-event-driven-pipeline --force
aws dynamodb delete-table --table-name tfstate-lock-event-pipeline --region ap-northeast-1
```

---

## トラブルシューティング

### `terraform init` が失敗する

```
Error: Failed to get existing workspaces: S3 bucket does not exist
```

→ 事前準備の S3 バケット作成が完了しているか確認してください。

```bash
aws s3 ls s3://tfstate-event-driven-pipeline
```

### Bedrock の呼び出しが `AccessDeniedException` で失敗する

```
Error: AccessDeniedException: You don't have access to the model with the specified model ID.
```

→ マネジメントコンソールで Bedrock のモデルアクセスを有効化してください（「前提条件」参照）。
承認後、有効化まで数分かかる場合があります。

### API Key なしでリクエストすると 403 になる

```json
{"message": "Forbidden"}
```

→ 正常な動作です。`-H "x-api-key: ${API_KEY}"` ヘッダーを付与してください。

### POST /jobs のレスポンスが 500 になる

```json
{"message": "Internal server error"}
```

→ API Gateway → SQS 直接統合のマッピングテンプレートまたは IAM 権限を確認してください。

```bash
# API Gateway のアクセスログを確認
aws logs filter-log-events \
  --log-group-name "/aws/apigateway/event-driven-pipeline-sandbox-dev" \
  --start-time $(date -d '10 minutes ago' +%s000) \
  --query "events[*].message" \
  --output text
```

### Step Functions の実行が FAILED になる

```bash
# 失敗した実行の詳細を確認
STATE_MACHINE_ARN=$(terraform output -raw state_machine_arn)

FAILED_EXEC=$(aws stepfunctions list-executions \
  --state-machine-arn "${STATE_MACHINE_ARN}" \
  --status-filter FAILED \
  --max-results 1 \
  --query "executions[0].executionArn" \
  --output text)

aws stepfunctions get-execution-history \
  --execution-arn "${FAILED_EXEC}" \
  --query "events[?type=='ExecutionFailed']" \
  --output json
```

### Lambda が VPC 内から AWS サービスに繋がらない

VPC エンドポイントが正しく設定されているか確認してください。

```bash
# VPC エンドポイントの一覧を確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query "VpcEndpoints[*].{Service:ServiceName,State:State}" \
  --output table
```

すべてのエンドポイントが `available` 状態であることを確認してください。

---

## コスト見積もり（月額目安）

| リソース | 概算 |
|---------|------|
| DynamoDB (on-demand) | ~$1 |
| SQS | ~$0.1 |
| Lambda | ~$0.1 |
| Step Functions | ~$1（Standard Workflow は $0.025/1000 状態遷移） |
| API Gateway REST | ~$0.5 |
| CloudWatch | ~$1 |
| NAT Gateway | ~$5 |
| **合計** | **~$10/月** |

> NAT Gateway は 1 台のみ（コスト最適化）。
> Step Functions の Standard Workflow は状態遷移ごとに課金されるため、実験後は削除推奨。
