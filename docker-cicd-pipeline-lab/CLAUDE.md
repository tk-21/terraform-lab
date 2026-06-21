# docker-cicd-pipeline-lab — CLAUDE.md

## プロジェクト概要

GitHub push をトリガーに Docker イメージをビルドし、ECS Fargate へ自動デプロイする
フルマネージド CI/CD パイプラインをTerraformで構築するポートフォリオ用ラボ。

```
GitHub → CodePipeline → CodeBuild (Docker build) → ECR → ECS Fargate (Blue/Green)
                                                             ↑
                                                        ALB (HTTP/80)
```

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| Terraform モジュール | `snake_case` | `ecs_service` |
| AWS リソース名 | `{project}-{env}-{resource}` | `cicd-lab-prod-cluster` |
| ECR リポジトリ | `{project}-app` | `cicd-lab-app` |
| S3 バケット | `{project}-{env}-{用途}-{account_id}` | `cicd-lab-prod-artifacts-123456` |
| IAM ロール | `{project}-{component}-role` | `cicd-lab-codebuild-role` |
| フェーズファイル | `phase{N}.md` | `phase1.md` ✅  `phase1_vpc.md` ❌ |

---

## ディレクトリ構成

```
docker-cicd-pipeline-lab/
├── CLAUDE.md                  # このファイル
├── README.md
├── docs/
│   ├── adr/
│   │   ├── 001-iac-tool.md
│   │   ├── 002-container-registry.md
│   │   ├── 003-deploy-strategy.md
│   │   └── 004-cost-design.md
│   └── architecture.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── networking/        # VPC, Subnets, SG
│       ├── ecr/               # ECR リポジトリ
│       ├── ecs/               # Cluster, Task Definition, Service
│       ├── alb/               # ALB, Target Group, Listener
│       ├── codebuild/         # CodeBuild Project + IAM
│       ├── codepipeline/      # Pipeline + S3 Artifact Store
│       └── iam/               # 各種 IAM ロール・ポリシー
├── app/
│   ├── Dockerfile
│   ├── app.py                 # シンプルなFlask/FastAPIアプリ
│   └── requirements.txt
├── buildspec/
│   └── buildspec.yml          # CodeBuild ビルド仕様
└── phase1.md ~ phase5.md
```

---

## 禁止事項 (FORBIDDEN)

```
# NAT Gateway は使用禁止 — 月額 $32+ のため
# 代替: ECR/S3 は VPC Endpoint (Gateway/Interface) 経由

# iam:* ワイルドカードポリシー禁止
# 最小権限原則を徹底すること

# latest タグのみの ECR イメージ禁止
# git commit SHA をタグとして必ず付与すること

# ハードコードされた AWS Account ID / Secret 禁止
# data "aws_caller_identity" を使用すること

# Public Subnet への ECS タスク直接配置禁止
# ALB 経由のみアクセスを許可する
```

---

## コスト設計原則

| コンポーネント | 選定 | 月額概算 |
|---|---|---|
| ECS Fargate | 0.25 vCPU / 0.5 GB × 1 task | ~$3 |
| ALB | 1台 | ~$16 |
| ECR | ~1GB ストレージ | ~$0.1 |
| CodeBuild | build.general1.small, 従量課金 | ~$1 |
| S3 (Artifact) | 標準 | ~$0.1 |
| VPC Endpoint | Interface × 2 (ECR) + Gateway × 1 (S3) | ~$15 |
| **合計** | | **~$35/月** |

> NAT Gateway を使わない代わりに VPC Endpoint を採用。
> ラボ終了後は `terraform destroy` を必ず実行すること。

---

## Terraform 規約

```hcl
# ✅ 正しい例: なぜその設定にしたかをコメントで説明（日本語）
resource "aws_ecs_service" "app" {
  # Blue/Green デプロイのため CodeDeploy コントローラーを使用
  # rolling update では ALB の接続が瞬断する可能性があるため
  deployment_controller {
    type = "CODE_DEPLOY"
  }
}

# ❌ 禁止例: 何をしているかだけのコメント
resource "aws_ecs_service" "app" {
  # ECS サービスの設定
}
```

- インラインコメントは **日本語** で「なぜ」を説明する
- 変数はすべて `variables.tf` に型・description・default を明記
- モジュール間の依存は output/input で明示的に管理
- `terraform fmt` / `terraform validate` はフェーズ完了前に必ず実行

---

## Docker 規約

```dockerfile
# ✅ マルチステージビルドを使用してイメージサイズを最小化
# ✅ ARM64 (arm64/v8) ベースイメージを優先 — Graviton コスト削減
# ✅ 非 root ユーザーで実行
# ✅ .dockerignore を必ず作成
# ❌ latest タグのベースイメージ禁止 — バージョン固定すること
```

---

## ADR 規約

- `docs/adr/` に Markdown で記録
- **AI生成文章をそのまま貼ることを禁止** — 自分の言葉で書くこと
- 構成: 背景 / 決定 / 理由 / トレードオフ / 代替案

---

## フェーズ実行方法

```bash
claude < phase1.md
claude < phase2.md
# ... 順番に実行すること
```

各フェーズ末尾に **完了チェックリスト** と **口頭説明チェックポイント** がある。
次フェーズに進む前に必ず確認すること。

---

## セルフチェックコマンド集

```bash
# Terraform 検証
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform validate

# Docker ローカルビルド確認
docker build -t cicd-lab-app:local ./app
docker run --rm -p 8080:8080 cicd-lab-app:local

# ECR ログイン確認
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --query Account --output text).dkr.ecr.ap-northeast-1.amazonaws.com

# パイプライン状態確認
aws codepipeline get-pipeline-state --name cicd-lab-prod-pipeline

# ECS タスク状態確認
aws ecs list-tasks --cluster cicd-lab-prod-cluster
```