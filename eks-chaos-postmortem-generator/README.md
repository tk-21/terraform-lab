# eks-chaos-postmortem-generator

> Chaos Engineering × AI — 障害を意図的に起こし、AIが人間より先にポストモーテムを書く

AWS Fault Injection Service（FIS）でEKSクラスターに意図的な障害を注入し、Amazon Bedrockが自動でポストモーテムドキュメントを生成するSREプラットフォームです。

---

## アーキテクチャ概要

```
FIS実験トリガー
    ↓
AWS Fault Injection Service（Pod Kill / Node Termination / Network Latency / CPU Stress）
    ↓ EventBridge
fis-event-handler Lambda（DynamoDB冪等性チェック）
    ↓ Step Functions
① data-collector  → CloudWatch Logs / Container Insights / CloudTrail / K8s Events
② bedrock-analyzer → Claude Sonnet 3.5 でポストモーテム生成（6項目バリデーション）
③ report-formatter → HTMLレポート生成 → S3保存 → presigned URL
④ notifier         → Chatwork通知
```

詳細は [docs/architecture.md](docs/architecture.md) を参照。

---

## 使用技術スタック

| カテゴリ | 技術 |
|---|---|
| IaC | Terraform（モジュール構造） |
| コンテナオーケストレーション | Amazon EKS 1.30 |
| カオスエンジニアリング | AWS Fault Injection Service |
| サーバーレス | AWS Lambda（Python 3.12 arm64） |
| ワークフロー | AWS Step Functions |
| AI | Amazon Bedrock（Claude Sonnet 3.5） |
| イベント駆動 | Amazon EventBridge |
| ストレージ | Amazon S3, Amazon DynamoDB |
| 通知 | Chatwork API |
| 可観測性 | AWS Lambda Powertools, X-Ray, CloudWatch |
| CI/CD | GitHub Actions（OIDC認証） |

---

## 前提条件

- AWS CLIセットアップ済み（`aws configure` 済み）
- Terraform >= 1.5.0
- kubectl
- Chatwork アカウントとAPIキー
- GitHub リポジトリ（GitHub Actions用）

---

## セットアップ手順

### 1. リポジトリクローン

```bash
git clone <repository_url>
cd eks-chaos-postmortem-generator
```

### 2. Terraformバックエンド設定

```bash
# S3バックエンドバケットを先に作成
aws s3 mb s3://eks-chaos-postmortem-tfstate --region ap-northeast-1
```

### 3. terraform.tfvars の設定

```bash
cp terraform/environments/dev/terraform.tfvars.example terraform/environments/dev/terraform.tfvars
# aws_account_id を自分のアカウントIDに変更
```

### 4. インフラ構築

```bash
cd terraform/environments/dev
terraform init
terraform plan
terraform apply
```

### 5. Chatwork APIキーの設定

```bash
aws secretsmanager put-secret-value \
  --secret-id "eks-chaos-postmortem/chatwork-api-key-dev" \
  --secret-string '{"api_key": "YOUR_API_KEY", "room_id": "YOUR_ROOM_ID"}' \
  --region ap-northeast-1
```

### 6. サンプルアプリのデプロイ

```bash
aws eks update-kubeconfig --name eks-chaos-postmortem-dev --region ap-northeast-1
kubectl apply -f k8s/sample-app/
```

---

## FIS実験の実行方法

```bash
# 実験テンプレートIDを確認
cd terraform/environments/dev && terraform output

# Pod Kill実験を開始
aws fis start-experiment \
  --experiment-template-id <pod_kill_template_id> \
  --region ap-northeast-1
```

3〜5分後にChatworkへポストモーテムが通知されます。詳細は [docs/runbook.md](docs/runbook.md) を参照。

---

## ポートフォリオとしてのポイント

### 技術的なチャレンジ

1. **Chaos Engineering の自動化**: FISトリガーからポストモーテム生成まで完全自動化
2. **AI活用**: BedrockのClaude Sonnet 3.5でSREエンジニアレベルのポストモーテムを自動生成
3. **6項目バリデーション**: AIの出力品質を構造的に保証するバリデーション機構
4. **冪等性設計**: DynamoDBのConditionExpressionで重複処理を防止
5. **最小権限IAM**: 全LambdaにIRSAを使用し、アクセスキーを一切使用しない
6. **モジュラーTerraform**: 7つのモジュールに分割した再利用可能なIaC

### SRE観点での設計

- **IRSA**: EKS Podへのアクセスキー不使用
- **StopCondition**: CPU 90%超で実験を自動停止（クラスター保護）
- **Lambda Powertools**: 構造化ログ・X-Rayトレーシングによる可観測性
- **Step Functions Retry**: 一時的な障害への自動リトライ
- **Chatwork通知**: 実験完了から数分以内にレポートを自動配信

---

## コスト

月次見積もり: **約$109**（EKSクラスター料金が大半）

検証後はノードグループを0台にスケールダウンすることでEC2コストを削減可能。
詳細は [docs/runbook.md](docs/runbook.md#コスト管理) を参照。

---

## ライセンス

MIT License
