# terraform-eks-production-platform

AWS上にVPCを設計し、セキュアなEKSクラスターをゼロから構築するハンズオンプロジェクト。
ネットワーク設計・セキュリティ・GitOps・可観測性をTerraformで完全IaC化する。

## アーキテクチャ概要

- **ネットワーク**: 3層VPC（Public / Private / Isolated）、2AZ構成
- **コンピュート**: EKS 1.29 + Karpenter（スポットインスタンス優先）
- **GitOps**: ArgoCD + ECR
- **可観測性**: CloudWatch Container Insights + AMP + AMG

## 前提条件

| ツール | バージョン |
|---|---|
| Terraform | >= 1.7.0 |
| AWS CLI | >= 2.0 |
| kubectl | >= 1.29 |
| helm | >= 3.14 |

### インストール確認

```bash
terraform version
aws --version
kubectl version --client
helm version
```

## セットアップ手順（初回のみ必要な手動作業）

### 1. Terraformバックエンド用S3バケット・DynamoDBテーブルの作成

バックエンドは自己参照できないため、初回のみ手動で作成する。

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export AWS_REGION=ap-northeast-1

# S3バケット作成
aws s3api create-bucket \
  --bucket "terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}" \
  --region ${AWS_REGION} \
  --create-bucket-configuration LocationConstraint=${AWS_REGION}

# バージョニング有効化
aws s3api put-bucket-versioning \
  --bucket "terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}" \
  --versioning-configuration Status=Enabled

# 暗号化有効化（SSE-S3）
aws s3api put-bucket-encryption \
  --bucket "terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# パブリックアクセスブロック
aws s3api put-public-access-block \
  --bucket "terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}" \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# DynamoDBテーブル作成（ステートロック用）
aws dynamodb create-table \
  --table-name terraform-eks-production-platform-prod-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ${AWS_REGION}
```

### 2. GitHub Actions用IAMロールの作成

OIDCを使ったGitHub ActionsのAWS認証ロールを作成する。
詳細は `docs/architecture.md` を参照。

```bash
# 別途 terraform/bootstrap/ ディレクトリで管理することを推奨
# 手順は docs/architecture.md に記載
```

### 3. `terraform.tfvars` の作成

```bash
cd terraform/environments/prod
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を環境に合わせて編集する
```

## デプロイ手順

```bash
cd terraform/environments/prod

# 1. 初期化（バックエンド接続）
terraform init

# 2. 差分確認
terraform plan

# 3. 適用
terraform apply
```

## 動作確認手順

```bash
# kubeconfig を更新
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name terraform-eks-production-platform-prod-cluster

# ノード確認（2台のManaged Node Groupノードが表示されるはず）
kubectl get nodes -o wide

# システムPodの確認
kubectl get pods -n kube-system

# Karpenter確認
kubectl get pods -n karpenter

# ArgoCD確認
kubectl get pods -n argocd

# ArgoCD UIアクセス（ポートフォワード）
kubectl port-forward svc/argocd-server -n argocd 8080:443
# ブラウザで https://localhost:8080 へアクセス
# パスワードはSecrets Managerから取得:
# aws secretsmanager get-secret-value --secret-id tep-prod-argocd-admin-password
```

## コスト削減（使用しないときは必ず destroy）

```bash
cd terraform/environments/prod

# 安全な削除（詳細は docs/cost-estimate.md を参照）
terraform destroy
```

## ディレクトリ構造

```
terraform-eks-production-platform/
├── terraform/
│   ├── environments/prod/   # 環境固有の設定
│   └── modules/
│       ├── vpc/             # VPCとサブネット設計
│       ├── eks/             # EKSクラスターとIRSA
│       ├── addons/          # ArgoCD, LBC, Karpenter
│       └── observability/   # CloudWatch, AMP, AMG
├── kubernetes/
│   ├── argocd/              # ArgoCDアプリケーション定義
│   ├── karpenter/           # NodePool設定
│   └── sample-app/          # サンプルアプリケーション
└── docs/                    # 設計ドキュメント
```
