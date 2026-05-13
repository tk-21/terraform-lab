# ✅Phase 1 — Terraform: AWS基盤構築

## このフェーズの前提

- CLAUDE.md を読み込み済みであること
- AWS CLI が設定済みで ap-northeast-1 にアクセス可能であること
- Terraform >= 1.7.0 がインストール済みであること

## このフェーズのゴール

以下の AWS リソースを Terraform で構築し、EKS クラスタが `kubectl` で操作できる状態にする。

1. S3 + DynamoDB（Terraformリモートステートバックエンド）
2. VPC（マルチAZ、パブリック/プライベートサブネット）
3. EKS クラスタ（マネージドノードグループ）
4. IAM ロール（EKS用、GitHub Actions OIDC用）
5. S3 レポートバケット

---

## Step 1: バックエンド初期化スクリプト

`scripts/bootstrap.sh` を作成する。

```
目的: Terraform のリモートステート用リソースを aws cli で作成する
（Terraformのバックエンド自身はTerraformで管理しない慣例に従う）
```

スクリプトの内容:
- S3 バケット作成: `istio-eks-tfstate-${AWS_ACCOUNT_ID}` （バージョニング有効化）
- DynamoDB テーブル作成: `istio-eks-tfstate-lock`（パーティションキー: `LockID`, 型: S）
- バケットのパブリックアクセスブロック設定（全てブロック）
- バケットのサーバーサイド暗号化設定（SSE-S3）
- 実行後に `terraform/backend.tf` のバケット名を自動置換する `sed` コマンドを出力

---

## Step 2: Terraform ファイル群

### `terraform/versions.tf`

```
required_version: >= 1.7.0
required_providers:
  aws: ~> 5.40
  kubernetes: ~> 2.27
  helm: ~> 2.13
```

### `terraform/backend.tf`

```
backend "s3":
  bucket: istio-eks-tfstate-REPLACE_WITH_ACCOUNT_ID
  key: istio-eks-service-mesh/terraform.tfstate
  region: ap-northeast-1
  dynamodb_table: istio-eks-tfstate-lock
  encrypt: true
```

### `terraform/variables.tf`

以下の変数を定義:
- `project_name` (string, default: "istio-eks-service-mesh")
- `env` (string, default: "dev")
- `aws_region` (string, default: "ap-northeast-1")
- `eks_cluster_version` (string, default: "1.29")
- `node_instance_type` (string, default: "t3.medium")
- `node_desired_size` (number, default: 2)
- `node_min_size` (number, default: 1)
- `node_max_size` (number, default: 3)
- `allowed_cidr_blocks` (list(string), description: "EKS API エンドポイントへのアクセス許可CIDR")
- `report_bucket_lifecycle_days` (number, default: 30)

### `terraform/main.tf`

module "vpc"、module "eks"、module "iam"、module "s3" を呼び出す。
各 module への input は variables.tf の変数と各モジュールの outputs を使用。

### `terraform/outputs.tf`

以下を出力:
- `eks_cluster_name`
- `eks_cluster_endpoint`
- `eks_cluster_certificate_authority_data`
- `eks_node_role_arn`
- `report_bucket_name`
- `vpc_id`
- `private_subnet_ids`

---

## Step 3: VPC モジュール

`terraform/modules/vpc/main.tf` を作成する。

### 設計要件（コメントに日本語で設計意図を記載）

```
# コスト最適化のため NAT Gateway は 1 AZ のみ構成
# ハンズオン環境のためHA冗長性より月額コストを優先する
```

リソース:
- `aws_vpc`: CIDR `10.0.0.0/16`, DNS ホスト名・DNS 解決を有効化
- `aws_subnet` (パブリック): AZ a/c に各 `/24`（`map_public_ip_on_launch = true`）
- `aws_subnet` (プライベート): AZ a/c に各 `/24`
- `aws_internet_gateway`
- `aws_eip`: NAT Gateway 用（AZ a のみ）
- `aws_nat_gateway`: パブリックサブネット AZ a に配置
- `aws_route_table` (パブリック): IGW 向けデフォルトルート
- `aws_route_table` (プライベート): NAT GW 向けデフォルトルート
- `aws_route_table_association`: 全サブネットに関連付け

タグ設計:
- パブリックサブネット: `kubernetes.io/role/elb = "1"`, `kubernetes.io/cluster/${var.cluster_name} = "shared"`
- プライベートサブネット: `kubernetes.io/role/internal-elb = "1"`, `kubernetes.io/cluster/${var.cluster_name} = "shared"`

outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`

---

## Step 4: IAM モジュール

`terraform/modules/iam/main.tf` を作成する。

### EKS クラスタロール

- `aws_iam_role`: `${var.project_name}-eks-cluster-role`
- Assume Role Policy: `eks.amazonaws.com`
- Attached Policies: `AmazonEKSClusterPolicy`

### EKS ノードグループロール

- `aws_iam_role`: `${var.project_name}-eks-node-role`
- Assume Role Policy: `ec2.amazonaws.com`
- Attached Policies:
  - `AmazonEKSWorkerNodePolicy`
  - `AmazonEC2ContainerRegistryReadOnly`
  - `AmazonEKS_CNI_Policy`
  - `AmazonSSMManagedInstanceCore`（Session Manager 経由のデバッグ用）

### GitHub Actions OIDC ロール

```
# OIDC経由でGitHub ActionsからAWSを操作するロール
# アクセスキーの発行を不要にするセキュリティベストプラクティス
```

- `aws_iam_openid_connect_provider`: `https://token.actions.githubusercontent.com`
- `aws_iam_role`: `${var.project_name}-github-actions-role`（64文字以内）
- Assume Role Policy: OIDC条件 `repo:YOUR_GITHUB_ORG/istio-eks-service-mesh:*`
- Inline Policy: EKS describe権限 + S3 レポートバケット書き込み権限のみ

outputs: `eks_cluster_role_arn`, `eks_node_role_arn`, `github_actions_role_arn`

---

## Step 5: EKS モジュール

`terraform/modules/eks/main.tf` を作成する。

### EKS クラスタ

```
# EKS APIエンドポイントはパブリック+プライベートのデュアル構成
# パブリックエンドポイントはCIDRホワイトリストで保護
```

- `aws_eks_cluster`:
  - `version`: `var.eks_cluster_version`
  - `role_arn`: cluster role
  - VPC config: プライベートサブネット配置、`endpoint_private_access = true`、`endpoint_public_access = true`、`public_access_cidrs = var.allowed_cidr_blocks`
  - Enabled log types: `["api", "audit", "authenticator"]`

### マネージドノードグループ

```
# Spot インスタンスでコストを最大 70% 削減
# ハンズオン環境のため中断リスクは許容する
```

- `aws_eks_node_group`:
  - `instance_types = [var.node_instance_type]`
  - `capacity_type = "SPOT"`
  - Scaling config: desired/min/max は variables から
  - `ami_type = "AL2023_x86_64_STANDARD"`
  - Labels: `role = "worker"`, `env = var.env`

### EKS アドオン

```
# VPC CNI, CoreDNS, kube-proxy は EKS マネージドアドオンで管理
# バージョン更新をAWSに委譲しセキュリティパッチを自動適用
```

- `aws_eks_addon`: `vpc-cni`, `coredns`, `kube-proxy`（各最新バージョン）

outputs: `cluster_name`, `cluster_endpoint`, `cluster_certificate_authority_data`, `oidc_issuer_url`

---

## Step 6: S3 モジュール

`terraform/modules/s3/main.tf` を作成する。

### レポートバケット

- `aws_s3_bucket`: `${var.project_name}-reports-${data.aws_caller_identity.current.account_id}`
- `aws_s3_bucket_versioning`: 有効化
- `aws_s3_bucket_server_side_encryption_configuration`: SSE-S3
- `aws_s3_bucket_public_access_block`: 全ブロック（署名付きURLでアクセス）
- `aws_s3_bucket_lifecycle_configuration`:
  - `expiration.days = var.lifecycle_days`（デフォルト30日）
- `aws_s3_bucket_cors_configuration`: GET のみ許可（HTMLレポートブラウザ表示用）

outputs: `bucket_name`, `bucket_arn`

---

## Step 7: ADR ドキュメント

`docs/adr/001-use-istio-over-appmesh.md` を作成する。

ADR フォーマット:
- Title, Date, Status: Accepted
- Context: サービスメッシュの選択理由
- Decision: Istio を選択した理由（ポータビリティ、OSS、Kiali可視化）
- Consequences: 運用複雑性とのトレードオフ

`docs/adr/002-eks-managed-nodegroup.md` を作成する。

- Context: セルフマネージドノード vs マネージドノードグループ
- Decision: マネージドノードグループ選択（AMI更新の自動化）
- Consequences: カスタマイズ性の制限

---

## Step 8: 実行確認コマンド

以下のコマンドを `docs/runbook/deploy.md` に記載すること:

```bash
# 1. バックエンドリソース作成
bash scripts/bootstrap.sh

# 2. Terraform 初期化
cd terraform && terraform init

# 3. 差分確認
terraform plan -var-file=dev.tfvars

# 4. 適用
terraform apply -var-file=dev.tfvars

# 5. kubectl 設定
aws eks update-kubeconfig \
  --region ap-northeast-1 \
  --name $(terraform output -raw eks_cluster_name)

# 6. ノード確認
kubectl get nodes -o wide
```

---

## Phase 1 完了条件

以下を満たしたら Phase 2 に進む:

- [ ] `terraform apply` がエラーなく完了
- [ ] `kubectl get nodes` で 2 ノードが `Ready` 状態
- [ ] `terraform output` で全 outputs が表示される
- [ ] S3 レポートバケットが存在する
- [ ] EKS CloudWatch Logs に api/audit ログが流れている

## Phase 2 への引き継ぎ情報

Phase 2 の冒頭で以下を確認すること:
```bash
export EKS_CLUSTER_NAME=$(cd terraform && terraform output -raw eks_cluster_name)
export REPORT_BUCKET=$(cd terraform && terraform output -raw report_bucket_name)
export AWS_REGION="ap-northeast-1"
```