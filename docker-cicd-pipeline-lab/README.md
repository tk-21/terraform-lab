# docker-cicd-pipeline-lab

GitHub への push を起点に Docker イメージをビルドし、ECS Fargate へ Blue/Green デプロイするまでを Terraform で完全自動化する CI/CD パイプライン構築ハンズオン。

---

## このハンズオンで得られること

### 構築できるもの

```
git push origin main
    │
    ▼
CodePipeline (Source) ──▶ CodeBuild (Docker build) ──▶ ECR
                                                         │
                                               CodeDeploy (Blue/Green)
                                                         │
                                               ECS Fargate ◀── ALB (Port 80)
```

コードを push するだけで本番環境へのデプロイが走る、実務レベルの CI/CD 基盤をゼロから構築できる。

### 習得できる技術・概念

| カテゴリ | 具体的な学習内容 |
|---|---|
| **Terraform** | モジュール分割設計、モジュール間の input/output 管理、循環依存の回避、`lifecycle.ignore_changes` の使いどころ |
| **コンテナ** | Docker マルチステージビルド、ARM64 (Graviton2) 向けクロスコンパイル (`buildx`)、非 root 実行 |
| **CI/CD** | CodePipeline のステージ設計、CodeBuild の buildspec 記述、`imagedefinitions.json` と `imageDetail.json` の違い |
| **Blue/Green デプロイ** | ゼロダウンタイム更新の仕組み、ALB リスナーによるトラフィック切り替え、ロールバック設計 |
| **ネットワーク** | NAT Gateway なし設計、VPC Endpoint (Gateway/Interface) による代替、プライベートサブネット上のコンテナ通信 |
| **IAM** | 最小権限原則の実装、サービスロール間の `iam:PassRole`、リソースレベル権限の限界と対処 |
| **可観測性** | Container Insights、CloudWatch Dashboard 設計、EventBridge によるパイプライン失敗検知 |

### このハンズオンが解決する「なぜ？」

- なぜ `privileged_mode = true` が CodeBuild で必要なのか
- なぜ ECS タスク定義に `ignore_changes` を付けるのか
- なぜ NAT Gateway を使わずに VPC Endpoint にしたのか
- なぜ `imageDetail.json` と `imagedefinitions.json` の両方が必要なのか
- なぜ `iam:PassRole` のリソースを絞る必要があるのか

詳細な設計ドキュメントは [ARCHITECTURE.md](./ARCHITECTURE.md) を参照。

---

## アーキテクチャ概要

```
Internet
    │
    ▼ (HTTP :80)
┌──────────────────────────────────────────────┐
│  ALB (internet-facing / パブリックサブネット)  │
│  Port 80  → Blue TG  (本番トラフィック)       │
│  Port 8080 → Green TG (テスト・切り替え時)    │
└──────────────────┬───────────────────────────┘
                   │
        ┌──────────▼──────────┐
        │ ECS Fargate (ARM64) │  プライベートサブネット
        │ Blue Task  (旧)     │
        │ Green Task (新)     │
        └──────────┬──────────┘
                   │ (インターネット非経由)
        ┌──────────▼──────────────────────┐
        │  VPC Endpoints                  │
        │  S3 (Gateway)   ← ECR レイヤー  │
        │  ECR API/DKR (Interface)        │
        │  CloudWatch Logs (Interface)    │
        └─────────────────────────────────┘
```

**コスト概算: 月額 ~$50** (NAT Gateway $32 の代わりに VPC Endpoint を採用)

---

## 技術スタック

| カテゴリ | 使用技術 |
|---|---|
| IaC | Terraform >= 1.6 |
| CI/CD | AWS CodePipeline + CodeBuild + CodeDeploy |
| コンテナ | Docker (ARM64/Graviton2), Amazon ECR |
| 実行環境 | Amazon ECS Fargate |
| ロードバランサー | Application Load Balancer |
| 可観測性 | CloudWatch Dashboard + Container Insights + EventBridge |

---

## 前提条件

### 必須ツールのバージョン確認

```bash
# Terraform
terraform version
# → Terraform v1.6.0 以上

# AWS CLI
aws --version
# → aws-cli/2.x.x 以上

# Docker (buildx プラグイン付き)
docker version
docker buildx version
# → BuildKit 対応バージョン

# Git
git --version
```

### AWS 認証設定の確認

```bash
# 認証情報が正しく設定されているか確認
aws sts get-caller-identity
# 出力例:
# {
#   "UserId": "AIDA...",
#   "Account": "123456789012",
#   "Arn": "arn:aws:iam::123456789012:user/your-user"
# }
```

使用する IAM ユーザー/ロールに以下のサービスへのアクセス権が必要:

- VPC / EC2 (Security Group)
- ECR
- ECS
- ALB (Elastic Load Balancing)
- CodeBuild / CodePipeline / CodeDeploy
- IAM (ロール・ポリシーの作成)
- S3
- CloudWatch / EventBridge
- CodeStar Connections

---

## ハンズオン手順

### Step 1: リポジトリをクローン

```bash
git clone https://github.com/{your-username}/docker-cicd-pipeline-lab.git
cd docker-cicd-pipeline-lab
```

---

### Step 2: GitHub Connection を AWS コンソールで作成

CodePipeline が GitHub リポジトリを監視するための OAuth 接続を作成する。
**この手順だけはコンソール操作が必須**（Terraform では Pending 状態にしかできない）。

1. AWS コンソールにログイン
2. **CodePipeline > 設定 > 接続** を開く
   - URL: `https://ap-northeast-1.console.aws.amazon.com/codesuite/settings/connections`
3. **「接続を作成」** をクリック
4. プロバイダーに **GitHub** を選択
5. 接続名を入力（例: `github-connection`）
6. **「GitHub に接続する」** をクリックして OAuth 認証を完了
7. 接続ステータスが **「利用可能」** になったことを確認
8. 接続の ARN をコピーしておく
   - 例: `arn:aws:codestar-connections:ap-northeast-1:123456789012:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

```bash
# CLI でも確認できる
aws codestar-connections list-connections \
  --provider-type GitHub \
  --query 'Connections[*].{Name:ConnectionName,ARN:ConnectionArn,Status:ConnectionStatus}' \
  --output table
```

---

### Step 3: tfvars ファイルを設定

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

`terraform/terraform.tfvars` を編集して以下の値を設定:

```hcl
# terraform/terraform.tfvars

aws_region   = "ap-northeast-1"
project_name = "cicd-lab"
environment  = "prod"

# Step 2 でコピーした ARN を貼り付ける
github_connection_arn = "arn:aws:codestar-connections:ap-northeast-1:123456789012:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

# GitHub のユーザー名または組織名
github_owner = "your-github-username"

# リポジトリ名 (URL の末尾部分)
github_repo   = "docker-cicd-pipeline-lab"
github_branch = "main"
```

> `terraform.tfvars` は `.gitignore` に含まれているため、誤って push される心配はない。

---

### Step 4: Terraform で AWS リソースを構築

```bash
# プロバイダーのダウンロードと初期化
terraform -chdir=terraform init
```

出力例:
```
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/aws versions matching "~> 5.0"...
- Installing hashicorp/aws v5.x.x...
Terraform has been successfully initialized!
```

```bash
# 作成されるリソースの確認 (apply 前に必ず確認)
terraform -chdir=terraform plan
```

主要リソース (約 40+ リソース) が表示される。問題なければ apply を実行:

```bash
terraform -chdir=terraform apply
```

確認プロンプトに `yes` と入力。完了まで **約 3〜5 分**。

```bash
# 出力値を確認
terraform -chdir=terraform output
```

出力例:
```
alb_dns_name                = "cicd-lab-prod-alb-1234567890.ap-northeast-1.elb.amazonaws.com"
ecr_repository_url          = "123456789012.dkr.ecr.ap-northeast-1.amazonaws.com/cicd-lab-prod-app"
ecs_cluster_name            = "cicd-lab-prod-cluster"
codepipeline_name           = "cicd-lab-prod-pipeline"
observability_dashboard_url = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/..."
```

> この時点では ECR にイメージが存在しないため ECS タスクは起動していない。次の Step で解消する。

---

### Step 5: 初回イメージを ECR に push

Terraform で ECR リポジトリが作成されたが、まだイメージが存在しない。
`initial-push.sh` を実行して最初のイメージを登録し、ECS タスクを起動させる。

```bash
# スクリプトを実行 (Docker が起動していること、AWS CLI が設定済みであることを確認)
./scripts/initial-push.sh
```

スクリプトの動作:
1. ECR にログイン
2. `./app` を ARM64 向けにビルドして ECR に push (`:latest` と `:initial` の2タグ)
3. ECS サービスを強制再起動 (`--force-new-deployment`)
4. タスクが `RUNNING` になるまで待機
5. ALB の DNS 名でヘルスチェックを実行

出力例:
```
=== ECR ログイン ===
Login Succeeded
=== arm64 イメージビルド & push ===
[+] Building 45.3s (12/12) FINISHED
=== ECS サービス再起動 ===
PRIMARY
=== タスク起動待機 (~1-2分) ===

✅ デプロイ完了
   ALB: http://cicd-lab-prod-alb-1234567890.ap-northeast-1.elb.amazonaws.com
{"status": "healthy"}
```

---

### Step 6: 動作確認

```bash
# ALB の DNS 名を取得
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
echo "ALB: http://$ALB_DNS"

# ヘルスチェック確認
curl -s http://$ALB_DNS/health | python3 -m json.tool
# 期待値:
# {
#     "status": "healthy"
# }

# アプリレスポンス確認
curl -s http://$ALB_DNS/ | python3 -m json.tool
# 期待値:
# {
#     "message": "Hello from ECS Fargate!",
#     "image_tag": "initial",
#     "hostname": "ip-10-0-10-xxx",
#     "timestamp": "2026-01-01T00:00:00+00:00"
# }
```

```bash
# ECS タスクが RUNNING であることを確認
aws ecs list-tasks \
  --cluster cicd-lab-prod-cluster \
  --query 'taskArns' \
  --output table

# パイプラインの状態確認
aws codepipeline get-pipeline-state \
  --name cicd-lab-prod-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --output table
```

---

### Step 7: CI/CD パイプラインを動かす

アプリケーションを変更して push すると、自動でビルド・デプロイが走ることを確認する。

```bash
# app/app.py のレスポンスメッセージを変更
sed -i 's/Hello from ECS Fargate!/Hello from Graviton2 Fargate! v2/' app/app.py

# 変更を push
git add app/app.py
git commit -m "feat: update greeting message"
git push origin main
```

**パイプラインの進捗を確認:**

```bash
# リアルタイムで状態をポーリング (Ctrl+C で停止)
watch -n 10 "aws codepipeline get-pipeline-state \
  --name cicd-lab-prod-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --output table"
```

| Stage | 所要時間の目安 | 確認ポイント |
|---|---|---|
| Source | ~10 秒 | GitHub からソースを取得 |
| Build | ~2〜4 分 | Docker ARM64 ビルド + ECR push |
| Deploy | ~2〜3 分 | Blue/Green 切り替え |

**デプロイ完了後、レスポンスに変更が反映されていることを確認:**

```bash
curl -s http://$ALB_DNS/ | python3 -m json.tool
# image_tag が git commit SHA (例: "a3f8c21d") に変わっていること
# message が "Hello from Graviton2 Fargate! v2" に変わっていること
```

---

### Step 8: Blue/Green デプロイの詳細を観察する

デプロイ中の CodeDeploy の状態を詳しく確認する。

```bash
# デプロイメント一覧を取得
aws deploy list-deployments \
  --application-name cicd-lab-prod-deploy \
  --deployment-group-name cicd-lab-prod-dg \
  --query 'deployments[0]' \
  --output text
```

```bash
# 上記で取得したデプロイメント ID を使って詳細確認
DEPLOYMENT_ID="d-XXXXXXXXX"

aws deploy get-deployment \
  --deployment-id $DEPLOYMENT_ID \
  --query 'deploymentInfo.{Status:status,Overview:deploymentOverview}' \
  --output json
```

**テスト用リスナー (Port 8080) で Green タスクを先行確認:**

デプロイ中 (Green タスクが起動してトラフィック切り替え前のタイミング) に:

```bash
# テストリスナーでアクセスすると新バージョンが返る
curl -s http://$ALB_DNS:8080/ | python3 -m json.tool
```

---

### Step 9: CloudWatch ダッシュボードで監視する

```bash
# ダッシュボード URL を取得してブラウザで開く
terraform -chdir=terraform output observability_dashboard_url
```

ダッシュボードで確認できる内容:

| ウィジェット | 確認ポイント |
|---|---|
| ECS 実行中タスク数 | デプロイ中は 2 (Blue + Green)、完了後は 1 |
| ALB HTTP レスポンスコード | 2xx が正常。5xx が増加したらデプロイ失敗 |
| ALB レイテンシ (p99) | 切り替え直後にスパイクがないか |
| CodeBuild ビルド時間 | ARM64 buildx の所要時間 |
| ECS CPU/Memory 使用率 | リソース使用状況 |

---

## トラブルシューティング

### ECS タスクが起動しない

```bash
# タスクの停止理由を確認
aws ecs describe-tasks \
  --cluster cicd-lab-prod-cluster \
  --tasks $(aws ecs list-tasks --cluster cicd-lab-prod-cluster --query 'taskArns[0]' --output text) \
  --query 'tasks[0].{Status:lastStatus,StopReason:stoppedReason,Containers:containers[*].{Name:name,Reason:reason}}' \
  --output json

# CloudWatch Logs でコンテナログを確認
aws logs get-log-events \
  --log-group-name /ecs/cicd-lab-prod/app \
  --log-stream-name $(aws logs describe-log-streams \
    --log-group-name /ecs/cicd-lab-prod/app \
    --order-by LastEventTime \
    --descending \
    --query 'logStreams[0].logStreamName' \
    --output text) \
  --limit 50 \
  --query 'events[*].message' \
  --output text
```

**よくある原因:**
- ECR にイメージが存在しない → `./scripts/initial-push.sh` を実行
- VPC Endpoint 経由で ECR に接続できない → セキュリティグループの Port 443 を確認
- タスク定義のメモリ不足 → `terraform/modules/ecs/variables.tf` の memory を増やす

---

### CodeBuild が失敗する

```bash
# ビルドログを確認
BUILD_ID=$(aws codebuild list-builds-for-project \
  --project-name cicd-lab-prod-build \
  --query 'ids[0]' --output text)

aws codebuild batch-get-builds \
  --ids $BUILD_ID \
  --query 'builds[0].{Status:buildStatus,Phase:currentPhase,Logs:logs.deepLink}' \
  --output json
```

**よくある原因:**
- Docker daemon に接続できない → `privileged_mode = true` の確認
- ECR へのログインが失敗 → CodeBuild IAM ロールの ECR 権限確認
- `docker buildx` がない → CodeBuild 標準イメージ `standard:7.0` を使用していることを確認

---

### CodeDeploy (Blue/Green) が失敗する

```bash
# デプロイメントイベントを確認
aws deploy get-deployment \
  --deployment-id $(aws deploy list-deployments \
    --application-name cicd-lab-prod-deploy \
    --deployment-group-name cicd-lab-prod-dg \
    --query 'deployments[0]' --output text) \
  --query 'deploymentInfo.{Status:status,Error:errorInformation}' \
  --output json
```

**よくある原因:**
- ヘルスチェック (`/health`) が失敗 → コンテナのログを確認
- タスク起動タイムアウト → `startPeriod` や ALB の `unhealthyThresholdCount` を調整
- `appspec.yml` の ContainerPort が間違っている → `8080` であることを確認

---

### GitHub Connection が `Pending` のまま

AWS コンソールで GitHub との OAuth 認証を完了させる必要がある。
Terraform だけでは `Available` 状態にできない。

**手順:**
1. コンソール → CodePipeline → 設定 → 接続
2. 該当の接続を選択 → 「保留中の接続を更新」
3. GitHub の認証画面で許可を完了

---

## パイプライン状態の確認コマンド集

```bash
# パイプライン全体の状態
aws codepipeline get-pipeline-state \
  --name cicd-lab-prod-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status,Updated:latestExecution.lastStatusChange}' \
  --output table

# ECS サービスの状態
aws ecs describe-services \
  --cluster cicd-lab-prod-cluster \
  --services cicd-lab-prod-service \
  --query 'services[0].{Status:status,Running:runningCount,Pending:pendingCount,Desired:desiredCount,Deployments:deployments[*].{Status:status,Count:runningCount}}' \
  --output json

# 最新の CodeBuild ビルド結果
aws codebuild list-builds-for-project \
  --project-name cicd-lab-prod-build \
  --query 'ids[:5]' --output text | \
  xargs aws codebuild batch-get-builds --ids \
  --query 'builds[*].{ID:id,Status:buildStatus,Duration:buildComplete}' \
  --output table

# ECR のイメージ一覧 (最新 5 件)
aws ecr describe-images \
  --repository-name cicd-lab-prod-app \
  --query 'sort_by(imageDetails, &imagePushedAt)[-5:].{Tag:imageTags[0],Pushed:imagePushedAt,Size:imageSizeInBytes}' \
  --output table
```

---

## クリーンアップ

**ラボ終了後は必ず実行してください。放置すると課金が継続します。**

### Step 1: ECR イメージを削除

ECR にイメージが残っていると `terraform destroy` が失敗する場合がある。

```bash
aws ecr delete-repository \
  --repository-name cicd-lab-prod-app \
  --force \
  --region ap-northeast-1
```

### Step 2: Terraform でリソースを削除

```bash
terraform -chdir=terraform destroy
```

確認プロンプトに `yes` と入力。完了まで約 5〜10 分。

削除されるリソース (約 40+):
- VPC / Subnet / Internet Gateway / Route Table
- VPC Endpoint (Interface × 3, Gateway × 1)
- Security Group × 3
- ALB / Target Group × 2 / Listener × 2
- ECS Cluster / Service / Task Definition
- ECR リポジトリ (Step 1 で削除済み)
- CodeBuild Project
- CodePipeline / CodeDeploy Application
- S3 バケット (アーティファクト)
- IAM ロール × 5 / ポリシー
- CloudWatch Log Group × 3 / Dashboard / Alarm × 2
- EventBridge Rule

### Step 3: GitHub Connection の削除 (オプション)

```bash
CONNECTION_ARN=$(aws codestar-connections list-connections \
  --provider-type GitHub \
  --query 'Connections[?ConnectionName==`github-connection`].ConnectionArn' \
  --output text)

aws codestar-connections delete-connection --connection-arn $CONNECTION_ARN
```

---

## 設計の意思決定

設計における「なぜ」は `docs/adr/` ディレクトリに記録している。

| ADR | タイトル |
|---|---|
| [001](./docs/adr/001-iac-tool.md) | IaC ツールの選定 (Terraform vs CDK vs CloudFormation) |
| [002](./docs/adr/002-container-registry.md) | コンテナレジストリの選定 (ECR vs Docker Hub) |
| [003](./docs/adr/003-deploy-strategy.md) | ECS デプロイ戦略 (Blue/Green vs Rolling Update) |
| [004](./docs/adr/004-cost-design.md) | NAT Gateway を使わない設計 (VPC Endpoint 代替) |

詳細なアーキテクチャ解説は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照。

---

## ポイント・学び

[ここに構築を通じて学んだことを自分の言葉で書く]
