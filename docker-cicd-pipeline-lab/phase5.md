# ✅Phase 5 — ADR・README・ポートフォリオ仕上げ

## このフェーズのゴール

GitHub に公開できる状態に仕上げる。
ADR を書くことで「なぜこの設計にしたか」を自分の言葉で説明できるようにする。

---

## 作成するファイル

### `docs/adr/001-iac-tool.md`

```markdown
# ADR 001 — IaC ツールの選定

## ステータス
採用

## 背景
<!-- ここは自分の言葉で書くこと (AI生成そのまま貼り禁止) -->
[なぜ IaC が必要だったか、どんな選択肢を検討したかを書く]

## 決定
Terraform を採用する

## 理由
<!-- 実際に手を動かして感じたことを書く -->
[Terraform を選んだ実際の理由を書く]

## トレードオフ
<!-- 良い面だけでなくデメリットも正直に書く -->
[Terraform の課題点も書く]

## 代替案
- AWS CDK (TypeScript)
- Pulumi (Python)
- CloudFormation
```

### `docs/adr/002-container-registry.md`

```markdown
# ADR 002 — コンテナレジストリの選定

## ステータス
採用

## 背景
[なぜプライベートレジストリが必要か、どんな要件があったかを書く]

## 決定
Amazon ECR を採用する

## 理由
[ECR を選んだ理由: IAM 統合、VPC Endpoint、コストなどを自分の視点で]

## トレードオフ
[ECR の制約や課題点]

## 代替案
- Docker Hub (Private)
- GitHub Container Registry (ghcr.io)
- Artifact Registry (GCP)
```

### `docs/adr/003-deploy-strategy.md`

```markdown
# ADR 003 — ECS デプロイ戦略の選定

## ステータス
採用

## 背景
[ECS のデプロイ方法がいくつかある中でどれを選ぶか検討した経緯]

## 決定
Blue/Green デプロイ (CodeDeploy) を採用する

## 理由
[Blue/Green を選んだ実際の理由を書く — 実際に設定してわかったことを含めて]

## トレードオフ
[Blue/Green のデメリット: 設定の複雑さ、コスト、制約など]

## 代替案
- Rolling Update (ECS デフォルト)
- Canary デプロイ
- CodeDeployDefault.ECSLinear10PercentEvery1Minute
```

### `docs/adr/004-cost-design.md`

```markdown
# ADR 004 — NAT Gateway を使わない設計

## ステータス
採用

## 背景
[ECS Fargate がプライベートサブネットにいて ECR/S3 に繋ぐ方法として
 NAT Gateway と VPC Endpoint の2択があった経緯]

## 決定
NAT Gateway を廃止し VPC Endpoint に全面移行する

## 理由
[コスト試算や実際の設定で気づいたことを書く]

## トレードオフ
[VPC Endpoint の制限: Interface Endpoint のコスト、対応サービスの制限など]

## 代替案
- NAT Gateway (月額 ~$32)
- NAT インスタンス (EC2 セルフ管理)
```

### `docs/architecture.md`

```markdown
# アーキテクチャ概要

## 全体構成図

```
Internet
    │
    ▼
┌─────────────┐
│     ALB     │  (パブリックサブネット)
│  port: 80   │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────┐
│          Private Subnet                 │
│  ┌──────────────┐  ┌──────────────┐    │
│  │ ECS Task(Blue│  │ECS Task(Green│    │
│  │  port: 8080  │  │  port: 8080  │    │
│  └──────────────┘  └──────────────┘    │
│         │                              │
│  ┌──────▼───────────────────────────┐  │
│  │        VPC Endpoints             │  │
│  │  ECR API / ECR DKR / S3 / Logs   │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘

GitHub → CodePipeline → CodeBuild → ECR → CodeDeploy → ECS
```

## デプロイフロー

1. `git push origin main`
2. CodePipeline (Source ステージ) が GitHub から最新コードを取得
3. CodeBuild が `buildspec/buildspec.yml` を実行
   - docker buildx で arm64 イメージをビルド
   - ECR に `{commit_hash}` タグで push
   - `imagedefinitions.json` / `imageDetail.json` を生成
4. CodeDeploy が Blue/Green デプロイを実行
   - Green 環境に新タスクを起動
   - ALB テストリスナー (8080) でヘルスチェック
   - 本番トラフィック (80) を Green に切り替え
   - 5分後に Blue 環境のタスクを終了

## コスト設計

NAT Gateway を使わず VPC Endpoint で ECR/S3/Logs への通信を実現。
月額概算: ~$35 (ALB が支配的)

## セキュリティ設計

- ECS タスクはプライベートサブネット配置 (インターネットから直接アクセス不可)
- ALB SG → ECS タスク SG の参照でタスクへの直接アクセスを制限
- ECR イメージスキャン (push 時) を有効化
- IAM ロールは最小権限で設計
```

---

## `README.md` の作成

```markdown
# docker-cicd-pipeline-lab

GitHub push → Docker build → ECR push → ECS Fargate Blue/Green deploy を
Terraform で自動化する CI/CD パイプライン構築ラボ。

## アーキテクチャ

```
GitHub → CodePipeline → CodeBuild → ECR → CodeDeploy → ECS Fargate
                                                ALB (Blue/Green)
```

## 技術スタック

| カテゴリ | 使用技術 |
|---|---|
| IaC | Terraform >= 1.6 |
| CI/CD | AWS CodePipeline + CodeBuild + CodeDeploy |
| コンテナ | Docker (arm64/Graviton2), Amazon ECR |
| 実行環境 | Amazon ECS Fargate |
| ロードバランサー | Application Load Balancer |
| 可観測性 | CloudWatch Dashboard + Container Insights |

## コスト概算

月額 ~$35 (NAT Gateway なし設計)

## セットアップ

### 前提条件
- AWS CLI 設定済み
- Terraform >= 1.6
- Docker + buildx

### デプロイ手順

```bash
# 1. GitHub Connection を AWS コンソールで作成
# CodePipeline > Settings > Connections > Create connection (GitHub)

# 2. tfvars 設定
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# github_connection_arn / github_owner / github_repo を編集

# 3. 初期デプロイ
terraform -chdir=terraform init
terraform -chdir=terraform apply -auto-approve

# 4. 初回イメージ push
./scripts/initial-push.sh

# 5. 動作確認
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
curl http://$ALB_DNS/health
```

### パイプライン実行

```bash
# app/app.py を変更して push するだけで自動デプロイ
git add app/app.py
git commit -m "feat: update response message"
git push origin main

# デプロイ状態確認
aws codepipeline get-pipeline-state --name cicd-lab-prod-pipeline
```

## クリーンアップ

```bash
terraform -chdir=terraform destroy -auto-approve
```

## 設計の意思決定

`docs/adr/` ディレクトリを参照。

## ポイント・学び

[ここに構築を通じて学んだことを自分の言葉で書く]
```

---

## `scripts/initial-push.sh` の作成

```bash
#!/usr/bin/env bash
# 初回 ECR push スクリプト
# terraform apply 直後に一度だけ実行する

set -euo pipefail

REGION="ap-northeast-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME="cicd-lab-prod-app"
REPO_URI="$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/$REPO_NAME"

echo "=== ECR ログイン ==="
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

echo "=== arm64 イメージビルド & push ==="
docker buildx create --use --name mybuilder 2>/dev/null || true
docker buildx build \
  --platform linux/arm64 \
  -t "$REPO_URI:latest" \
  -t "$REPO_URI:initial" \
  ./app \
  --push

echo "=== ECS サービス再起動 ==="
aws ecs update-service \
  --cluster cicd-lab-prod-cluster \
  --service cicd-lab-prod-service \
  --force-new-deployment \
  --query 'service.deployments[0].status' \
  --output text

echo "=== タスク起動待機 (~1-2分) ==="
aws ecs wait services-stable \
  --cluster cicd-lab-prod-cluster \
  --services cicd-lab-prod-service

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names cicd-lab-prod-alb \
  --query 'LoadBalancers[0].DNSName' --output text)

echo ""
echo "✅ デプロイ完了"
echo "   ALB: http://$ALB_DNS"
curl -s "http://$ALB_DNS/health" | python3 -m json.tool
```

---

## 実行手順

```bash
# 1. スクリプトに実行権限
chmod +x scripts/initial-push.sh

# 2. ADR を書く (AI生成をそのまま使わないこと)
# docs/adr/*.md の [ここに書く] 部分を自分の言葉で埋める

# 3. README の「ポイント・学び」を書く

# 4. GitHub リポジトリを作成して push
git init
git add .
git commit -m "feat: initial commit — docker-cicd-pipeline-lab"
git remote add origin https://github.com/{your-username}/docker-cicd-pipeline-lab.git
git push -u origin main

# 5. 最終動作確認
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
echo "=== ヘルスチェック ==="
curl -s http://$ALB_DNS/health | python3 -m json.tool

echo "=== アプリレスポンス ==="
curl -s http://$ALB_DNS/ | python3 -m json.tool

echo "=== パイプライン状態 ==="
aws codepipeline get-pipeline-state \
  --name cicd-lab-prod-pipeline \
  --query 'stageStates[*].{Stage:stageName,Status:latestExecution.status}' \
  --output table
```

---

## 完了チェックリスト

- [ ] ADR 4本が自分の言葉で書かれている (AI 丸写し NG)
- [ ] README に手順が書かれていて第三者が再現できる
- [ ] GitHub リポジトリに push されている
- [ ] ラボ全体の動作が end-to-end で確認できている
- [ ] `terraform destroy` でリソースがすべて削除できる

## 最終口頭説明チェックポイント

> このプロジェクト全体を面接官に 10 分で説明できるか確認すること

1. **このシステムのアーキテクチャを図を描いて説明できるか？**
2. **NAT Gateway を使わなかった理由と、代替手段のトレードオフは？**
3. **Blue/Green デプロイの流れをシーケンスで説明できるか？**
4. **buildspec.yml で imageDetail.json が必要な理由は？**
5. **CodeBuild で privileged_mode = true が必要な理由は？**
6. **コスト削減のために何を工夫したか？ (具体的な金額込みで)**
7. **もし本番で使うなら何を追加するか？** (HTTPS, WAF, Auto Scaling など)

---

## クリーンアップ

```bash
# ラボ終了後は必ず実行
terraform -chdir=terraform destroy -auto-approve

# ECR イメージも削除
aws ecr delete-repository \
  --repository-name cicd-lab-prod-app \
  --force \
  --region ap-northeast-1
```