# ✅Phase 2: Atlantis on ECS Fargate 構築

## このフェーズの前提

Phase 1が完了していること：
- `tfstate-pr-driven-iac-lab-{account_id}` S3バケットが存在
- `tfstate-lock-pr-driven-iac-lab` DynamoDBテーブルが存在
- `terraform/sample-infra/` のコードが完成

## このフェーズの目的

- Atlantis を ECS Fargate（arm64 + FARGATE_SPOT）でホスティング
- GitHub Webhook で PR イベントを Atlantis に転送
- Atlantis が AWS に対して terraform plan/apply を実行できる IAM 権限を付与
- NAT Gateway なし（VPC Endpoints のみ）でコスト最適化

## アーキテクチャ概要

```
GitHub PR/Comment
    ↓ webhook (HTTPS)
ALB (Internet-facing)
    ↓
ECS Fargate (Atlantis container, arm64, FARGATE_SPOT)
    ↓ IAM Role (OIDC不可のためTask Role)
AWS APIs (S3, DynamoDB, IAM, etc.)

VPC Endpoints:
  - com.amazonaws.ap-northeast-1.s3 (Gateway型、無料)
  - com.amazonaws.ap-northeast-1.dynamodb (Gateway型、無料)
  - com.amazonaws.ap-northeast-1.ecr.api
  - com.amazonaws.ap-northeast-1.ecr.dkr
  - com.amazonaws.ap-northeast-1.logs
```

## タスク 2-1: GitHub Personal Access Token の準備

以下の権限を持つ GitHub PAT を作成し、SSM Parameter Store に保存：

```bash
# GitHubで Fine-grained token または Classic token を作成
# 必要権限: repo（full）, admin:repo_hook

aws ssm put-parameter \
  --name "/atlantis/github-token" \
  --value "ghp_xxxxxxxxxxxx" \
  --type "SecureString" \
  --region ap-northeast-1

aws ssm put-parameter \
  --name "/atlantis/webhook-secret" \
  --value "$(openssl rand -hex 32)" \
  --type "SecureString" \
  --region ap-northeast-1
```

webhook-secret の値を手元にメモしておくこと（GitHub Webhook設定で使用）。

## タスク 2-2: terraform/atlantis-infra/ の作成

### `terraform/atlantis-infra/backend.tf`

```hcl
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "tfstate-pr-driven-iac-lab-PLACEHOLDER"
    key            = "atlantis-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-pr-driven-iac-lab"
    encrypt        = true
  }
}

provider "aws" {
  region = "ap-northeast-1"
}
```

### `terraform/atlantis-infra/variables.tf`

以下の変数を定義：
- `github_repo_owner`: string（GitHubユーザー名/組織名）
- `github_repo_name`: string（リポジトリ名、default = "pr-driven-iac-lab"）
- `atlantis_image`: string（default = "ghcr.io/runatlantis/atlantis:latest"）
- `atlantis_port`: number（default = 4141）

### `terraform/atlantis-infra/main.tf`

**VPC構成:**
- VPC CIDR: 10.0.0.0/16
- パブリックサブネット x2（ALB用）: 10.0.1.0/24, 10.0.2.0/24
- プライベートサブネット x2（ECS用）: 10.0.10.0/24, 10.0.11.0/24
- Internet Gateway（ALBのアウトバウンド用）
- NAT Gateway: **作成しない**
- VPC Endpoints（プライベートサブネットからAWSサービスアクセス用）:
  - S3 Gateway Endpoint（無料）
  - DynamoDB Gateway Endpoint（無料）
  - ECR API Interface Endpoint
  - ECR DKR Interface Endpoint
  - CloudWatch Logs Interface Endpoint

日本語コメント: 各Endpointがなぜ必要かを記述

### `terraform/atlantis-infra/ecs.tf`

**ECS Cluster:**
- クラスター名: `atlantis-cluster`
- Container Insights: 有効

**ECS Task Definition:**
- family: `atlantis`
- CPU: 512, Memory: 1024
- network_mode: `awsvpc`
- requires_compatibilities: `["FARGATE"]`
- runtime_platform: `LINUX_ARM64`（コスト最適化）
- コンテナ定義:
  - image: `var.atlantis_image`
  - portMappings: 4141
  - 環境変数:
    - `ATLANTIS_GH_USER`: GitHubユーザー名
    - `ATLANTIS_REPO_ALLOWLIST`: `github.com/{owner}/{repo}`
    - `ATLANTIS_PORT`: "4141"
    - `ATLANTIS_ATLANTIS_URL`: `https://{ALB DNS名}`（後でALB作成後に更新）
  - secrets（SSM Parameter Storeから取得）:
    - `ATLANTIS_GH_TOKEN`: `/atlantis/github-token`
    - `ATLANTIS_GH_WEBHOOK_SECRET`: `/atlantis/webhook-secret`
  - logConfiguration: CloudWatch Logs（ロググループ: `/ecs/atlantis`）

**ECS Service:**
- サービス名: `atlantis`
- desired_count: 1
- capacity_provider_strategy:
  - FARGATE_SPOT: weight=100（コスト最適化、本番では FARGATE:1 を混ぜる）
- network_configuration: プライベートサブネット、セキュリティグループ
- load_balancer: ALBターゲットグループと紐付け
- deployment_minimum_healthy_percent: 0（1台構成のため）
- deployment_maximum_percent: 100

### `terraform/atlantis-infra/alb.tf`

**ALB（Application Load Balancer）:**
- internal: false（Internet-facing、GitHubからのwebhook受信のため）
- パブリックサブネットに配置
- セキュリティグループ: HTTPS(443) を 0.0.0.0/0 から許可

**Target Group:**
- port: 4141, protocol: HTTP
- health_check: path = `/healthz`, interval = 30

**Listener:**
- HTTPS 443（ACM証明書が必要）
  - 証明書がない場合の代替: HTTP 80 でまず動作確認し、HTTPS化は後続タスクで実施
- リダイレクト: HTTP 80 → HTTPS 443

**注意**: ACM証明書はカスタムドメインが必要。
ドメインがない場合は HTTP 80 のみで動作確認を行い、その旨をコメントに記述。

### `terraform/atlantis-infra/iam.tf`

**ECS Task Execution Role:**
- 名前: `atlantis-task-execution-role`（64文字以内）
- AmazonECSTaskExecutionRolePolicy をアタッチ
- SSM Parameter Store の `/atlantis/*` を読み取る追加ポリシー

**ECS Task Role（AtlantisがTerraformを実行する権限）:**
- 名前: `atlantis-task-role`（64文字以内）
- 以下の権限を付与（sample-infraのリソースを操作できる最小権限）:

```hcl
# sample-infra が管理するリソースへの権限
# S3: バケット作成・管理
# IAM: ロール・ポリシー作成・管理
# DynamoDB: Terraformステートロックの読み書き
# S3: Terraformステートの読み書き
```

wildcard禁止。リソースARNを明示的に指定すること。
日本語コメント: なぜTask RoleとExecution Roleを分離するかを記述。

### `terraform/atlantis-infra/outputs.tf`

- alb_dns_name
- ecs_cluster_name
- ecs_service_name
- task_role_arn

## タスク 2-3: atlantis-infra の apply 実行

```bash
cd terraform/atlantis-infra
terraform init
terraform plan
terraform apply
```

apply成功後：
1. `alb_dns_name` の出力値を確認
2. ECS Task Definition の `ATLANTIS_ATLANTIS_URL` を ALB DNS 名で更新
3. `terraform apply` を再実行

## タスク 2-4: GitHub Webhook の設定

GitHubリポジトリの Settings > Webhooks で以下を設定：

```
Payload URL: http://{alb_dns_name}/events
  （HTTPS化している場合は https://）
Content type: application/json
Secret: （SSMに保存したwebhook-secret の値）
Events: Pull requests, Issue comments, Push
```

## タスク 2-5: Atlantis 動作確認

```bash
# ECS タスクのログ確認
aws logs tail /ecs/atlantis --follow --region ap-northeast-1

# Atlantis ヘルスチェック
curl http://{alb_dns_name}/healthz
# 期待レスポンス: {"status":"ok"}
```

## タスク 2-6: sample-infra への初回 plan テスト

```bash
# sample-infra の backend.tf が設定済みであることを確認
cd terraform/sample-infra
terraform init

# テスト用ブランチを作成してPRを出す
git checkout -b test/phase2-atlantis-check
# terraform/sample-infra/main.tf に無害な変更（タグ追加など）
echo '  ExtraTag = "phase2-test"' >> terraform/sample-infra/main.tf
git add -A
git commit -m "test: Phase2 Atlantis動作確認用の変更"
git push origin test/phase2-atlantis-check
gh pr create --title "test: Atlantis動作確認" --body "Phase 2 Atlantis疎通テスト"
```

PRを作成後、数十秒以内に Atlantis が PR にコメント（plan結果）を投稿することを確認。

## Phase 2 完了確認チェックリスト

- [ ] `terraform/atlantis-infra/` apply 成功
- [ ] ECS Fargate タスクが RUNNING 状態
- [ ] `curl http://{alb_dns_name}/healthz` が `{"status":"ok"}` を返す
- [ ] GitHub Webhook が設定済み（Recent Deliveries に成功ログ）
- [ ] テスト PR に Atlantis の plan コメントが投稿された
- [ ] VPC に NAT Gateway が存在しない（VPC Endpoints のみ）
- [ ] ECS Task が arm64 / FARGATE_SPOT で動作している

## 口頭説明チェックポイント（Phase 2終了後）

以下を15分間、ノートなしで説明できること：

1. **AtlantisのIAM設計**
   - Task Role と Execution Role の違い
   - AtlantisのTask RoleにAdministratorAccessを与えてはいけない理由
   - 最小権限をどう決めたか

2. **NAT Gateway を使わない設計の意味**
   - VPC Endpoints の種類（Gateway vs Interface）とコスト差
   - プライベートサブネットの ECS タスクが ECR からイメージをPullできる仕組み

3. **Atlantis のWebhookフロー**
   - PR open → webhook → Atlantis → plan → PRコメント の各ステップ
   - `atlantis.yaml` の `autoplan.when_modified` の意味