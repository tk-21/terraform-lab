# CLAUDE.md — terraform-eks-production-platform

## プロジェクト概要

AWS上にゼロからVPCを設計し、その上にセキュアなEKSクラスターを構築するハンズオンプロジェクト。
ネットワーク設計・セキュリティ・GitOps・可観測性までをTerraformで完全IaC化する。

## ゴール

- 3層VPCネットワーク（Public / Private / Isolated）の設計と実装
- EKSクラスター（IRSA・Karpenter・aws-auth管理）の構築
- GitOps基盤（ArgoCD + ECR）の構築
- 可観測性（CloudWatch Container Insights + Managed Prometheus + Grafana）の構築

## ターゲット環境

- **AWSリージョン**: ap-northeast-1（東京）
- **Terraform**: >= 1.7.0
- **Python**: 3.12（Lambda使用時）
- **AZ**: ap-northeast-1a / ap-northeast-1c の2AZ構成

## ディレクトリ構造

Claude Codeはこの構造を厳守してファイルを生成すること。

```
terraform-eks-production-platform/
├── CLAUDE.md
├── README.md
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml        # PRでterraform plan
│       └── terraform-apply.yml       # mainマージでterraform apply
├── terraform/
│   ├── environments/
│   │   └── prod/
│   │       ├── main.tf               # モジュール呼び出し
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       ├── terraform.tfvars
│   │       └── backend.tf            # S3 + DynamoDB
│   └── modules/
│       ├── vpc/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── eks/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── irsa.tf               # IRSA用IAMロール
│       ├── addons/
│       │   ├── main.tf               # ArgoCD, LBC, Karpenter
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── observability/
│           ├── main.tf               # AMP, AMG, Container Insights
│           ├── variables.tf
│           └── outputs.tf
├── kubernetes/
│   ├── argocd/
│   │   └── applications/             # ArgoCDアプリケーション定義
│   ├── karpenter/
│   │   └── node-pool.yaml            # Karpenter NodePool
│   └── sample-app/
│       ├── deployment.yaml
│       └── service.yaml
└── docs/
    ├── architecture.md               # アーキテクチャ解説
    ├── network-design.md             # CIDR設計の意思決定
    └── cost-estimate.md              # コスト試算
```

## コーディング規約

### Terraform全般

- **命名規則**: `{project}-{env}-{resource}` 例: `terraform-eks-production-platform-prod-vpc`
- **タグ必須**: すべてのリソースに以下のタグを付与すること

```hcl
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}
```

- **変数**: すべての変数に `description` と `type` を必ず記載
- **コメント**: 「なぜこの設定か」を日本語コメントで必ず記載。設定値の説明だけでは不十分

```hcl
# VPC CIDRを /16 にする理由：
# サブネット分割の柔軟性を確保するため。/24 を最小単位として
# Public×2 + Private×2 + Isolated×2 の6サブネットを収容しつつ、
# 将来的なAZ追加や用途別サブネット増設に対応できるよう /16 を採用。
variable "vpc_cidr" {
  description = "VPC全体のCIDRブロック。/16を推奨"
  type        = string
  default     = "10.0.0.0/16"
}
```

- **出力値**: 他モジュールが参照する可能性があるIDはすべてoutputsに定義
- **プロバイダーバージョン**: `~>` 記法で指定。メジャーバージョンは固定

### セキュリティ原則

- IAMポリシーは最小権限。`*` リソース指定は原則禁止
- セキュリティグループはインバウンドを明示的に定義。0.0.0.0/0 は ALB のみ許可
- Secrets ManagerまたはSSM Parameter Storeを使用。ハードコード禁止
- EKSのPublic API Endpointは `public_access_cidrs` で制限すること

### EKS固有

- Node Groupのインスタンスタイプは変数化し、コスト最適化コメントを記載
- IRSAは用途ごとにIAMロールを分離（Karpenter用・LBC用・ArgoCD用・アプリ用）
- `aws-auth` ConfigMapはTerraform管理（手動編集禁止）

## ネットワーク設計（参照用）

### CIDR設計

| サブネット種別 | AZ-a | AZ-c | 用途 |
|---|---|---|---|
| Public | 10.0.0.0/24 | 10.0.1.0/24 | ALB, NAT Gateway |
| Private | 10.0.10.0/23 | 10.0.12.0/23 | EKS Node Group, Pod |
| Isolated | 10.0.20.0/24 | 10.0.21.0/24 | RDS, ElastiCache |

> Privateを /23 にする理由：EKSはPodにもVPC IPを消費する（VPC CNI）。
> t3.medium は最大17Pod。Node 10台想定で170IP必要なため /23（510IP）を確保。

### VPC Endpoints（必須）

| エンドポイント | タイプ | 理由 |
|---|---|---|
| S3 | Gateway | ECRイメージレイヤーはS3経由。NAT料金削減 |
| ECR API | Interface | プライベートサブネットからECR認証 |
| ECR DKR | Interface | コンテナイメージPull |
| Secrets Manager | Interface | 秘匿情報取得をVPC内で完結 |
| STS | Interface | IRSA（ServiceAccountトークン検証） |
| CloudWatch Logs | Interface | Container Insightsログ送信 |

## GitHub Actions設定

### 認証方式
- **OIDC**（アクセスキー不使用）
- IAMロール: `arn:aws:iam::${AWS_ACCOUNT_ID}:role/github-actions-eks-platform`

### ワークフロー動作
- `terraform-plan.yml`: PRオープン時に `terraform plan` を実行しPRコメントに結果を投稿
- `terraform-apply.yml`: `main` ブランチへのマージ時に `terraform apply -auto-approve` を実行

## コスト管理

- **月次目標**: ハンズオン学習目的のため、使用しない時間は `terraform destroy` を実行
- **Karpenter**: オンデマンドではなくスポットインスタンスを優先設定
- **NAT Gateway**: 2AZ分で約$65/月かかるため、検証時は1AZに絞る選択肢をコメントで明示

## 禁止事項

- アクセスキー・シークレットキーのハードコード
- `terraform.tfstate` のGitコミット（.gitignoreに必ず追加）
- `terraform.tfvars` に秘匿情報を記載（サンプル値のみ）
- IAMの `AdministratorAccess` 付与（最小権限で代替）

## 参考アーキテクチャ

AWS公式EKSベストプラクティスガイド、AWS Well-Architected Frameworkに準拠。
IRSAはOIDC Providerを使用した標準的な実装とする。