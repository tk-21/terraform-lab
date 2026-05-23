# ai-inference-pipeline — CLAUDE.md

## プロジェクト概要
S3トリガー → Step Functions → ECS Fargate（Docker前処理）→ Lambda × Bedrock（AI推論）→ DynamoDB → Chatwork通知
のAI推論パイプラインをTerraformで構築するポートフォリオプロジェクト。

## 実行方法
```bash
claude < phase1.md
claude < phase2.md
# ...
```

---

## 命名規約

| リソース | パターン | 例 |
|---|---|---|
| Terraformモジュール | スネークケース | `module "ecs_task"` |
| AWSリソース | `aip-{env}-{resource}` | `aip-dev-preprocessor` |
| S3バケット | `aip-{env}-{purpose}-{account_id}` | `aip-dev-input-123456789` |
| ECRリポジトリ | `aip/{env}/{name}` | `aip/dev/preprocessor` |
| Lambdaファイル名 | `{function_name}/main.py` | `invoke_bedrock/main.py` |
| DynamoDBテーブル | `aip-{env}-results` | `aip-dev-results` |
| Step Functions SM | `aip-{env}-inference-pipeline` | |
| IAMロール | `aip-{env}-{component}-role` | `aip-dev-ecs-task-role` |
| CloudWatch LogGroup | `/aip/{env}/{component}` | `/aip/dev/ecs` |

## ディレクトリ構成
```
ai-inference-pipeline/
├── CLAUDE.md
├── terraform/
│   ├── modules/
│   │   ├── s3/
│   │   ├── iam/
│   │   ├── ecr/
│   │   ├── ecs/
│   │   ├── lambda/
│   │   ├── step_functions/
│   │   ├── dynamodb/
│   │   └── eventbridge/
│   └── environments/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── terraform.tfvars
├── docker/
│   └── preprocessor/
│       ├── Dockerfile
│       ├── main.py
│       └── requirements.txt
├── lambda/
│   ├── invoke_bedrock/
│   │   └── main.py
│   └── notify_chatwork/
│       └── main.py
├── docs/
│   └── adr/
│       ├── 001-use-step-functions.md
│       ├── 002-use-ecs-fargate-for-preprocessing.md
│       └── 003-bedrock-model-selection.md
└── scripts/
    ├── build_and_push.sh
    ├── upload_test_data.sh
    └── cleanup.sh
```

---

## 禁則事項（絶対に守ること）

### コスト管理
- **NAT Gateway は使用禁止** → VPC Endpointで代替（ECR, S3, Bedrock, DynamoDB, Logs, Step Functions, ECS）
- ECS タスク: Fargate Spot を優先（`FARGATE_SPOT` capacity provider）
- Lambda: arm64 アーキテクチャ必須（`architectures = ["arm64"]`）
- DynamoDB: PAY_PER_REQUEST（オンデマンド）必須
- ECR: `image_tag_mutability = "MUTABLE"` + lifecycle policy（最新3世代のみ保持）
- Bedrock: `claude-haiku` をデフォルト使用（コスト最小）

### セキュリティ
- Lambda/ECSのIAMロールには最小権限のみ付与
- `*` ワイルドカードリソースは原則禁止（S3バケットARN等は具体的に指定）
- S3バケット: パブリックアクセスブロック必須
- Secrets: Chatwork Token は SSM Parameter Store（SecureString）で管理

### Terraform
- `terraform.tfvars` に機密情報を書かない
- 全リソースに `tags` ブロック必須（`Project`, `Env`, `ManagedBy` の3つ最低限）
- `locals` ブロックでタグを一元管理する
- モジュールは `terraform/modules/` 配下に分割、環境は `environments/dev/` から呼び出す
- state は local（ハンズオン用途のためS3 remote stateは任意）

### コードスタイル
- Terraformコメント: **日本語で「なぜ」を説明する**（何をするかではなく）
- Pythonコメント: 日本語で記述
- Dockerfileコメント: 日本語
- ADRの「決定の根拠」セクションはAI生成禁止・自分の言葉で記述

---

## 共通タグ（locals で定義）
```hcl
locals {
  common_tags = {
    Project    = "ai-inference-pipeline"
    Env        = var.env
    ManagedBy  = "terraform"
  }
}
```

## Lambda 共通設定
```hcl
runtime      = "python3.12"
architectures = ["arm64"]
timeout      = 60
memory_size  = 256
```

## Bedrock設定
- デフォルトモデル: `anthropic.claude-3-haiku-20240307-v1:0`
- リージョン: `ap-northeast-1`
- InvokeModel APIを使用（Agents不要の場合）

## Chatwork通知
- エンドポイント: `https://api.chatwork.com/v2/rooms/{room_id}/messages`
- 認証: `X-ChatWorkToken` ヘッダー
- Content-Type: `application/x-www-form-urlencoded`
- トークンはSSM `/aip/{env}/chatwork/token` から取得

## フェーズ一覧
| フェーズ | 内容 |
|---|---|
| phase1 | Terraform基盤（VPC endpoints, S3, DynamoDB, ECR, IAM） |
| phase2 | Dockerコンテナ（前処理）+ ECRビルド&プッシュスクリプト |
| phase3 | Lambda（Bedrock推論 + Chatwork通知） |
| phase4 | Step Functions ステートマシン定義 |
| phase5 | EventBridge + S3トリガー連携・E2Eテスト |
| phase6 | ADR作成・口頭説明チェックポイント |