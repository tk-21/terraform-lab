# Claude Code 統合プロンプト
# terraform-eks-production-platform

---

以下の指示をすべて読んだうえで、CLAUDE.mdの内容に従い、
`terraform-eks-production-platform/` プロジェクト全体を一括生成してください。

---

## あなたの役割

あなたはAWSインフラの専門家です。
CLAUDE.mdに定義されたディレクトリ構造・コーディング規約・ネットワーク設計をすべて遵守し、
実務で即使えるレベルのTerraformコードとKubernetesマニフェストを生成してください。

コードの品質基準：
- 「なぜこの設定か」の設計意図を日本語コメントで必ず記載する
- サンプルや仮置きは不可。実際にapplyできる完成形を生成する
- セキュリティベストプラクティスを常に適用する

---

## Step 1: バックエンド・プロバイダー設定

以下のファイルを生成してください。

### `terraform/environments/prod/backend.tf`

- S3バケット名: `terraform-eks-production-platform-prod-tfstate-${AWS_ACCOUNT_ID}`
- DynamoDBテーブル名: `terraform-eks-production-platform-prod-tfstate-lock`
- キー: `terraform-eks-production-platform/prod/terraform.tfstate`
- リージョン: ap-northeast-1
- S3バケットはバージョニング有効・暗号化（SSE-S3）有効

### `terraform/environments/prod/main.tf`（プロバイダー定義部分）

```hcl
# 使用するプロバイダーとバージョンを明示する
# hashicorp/aws ~> 5.0
# hashicorp/kubernetes ~> 2.0
# hashicorp/helm ~> 2.0
```

---

## Step 2: VPCモジュール生成

`terraform/modules/vpc/` 配下の全ファイルを生成してください。

### 必須リソース（すべて実装すること）

**ネットワーク基盤**
- `aws_vpc`: DNS解決・DNSホスト名を有効化
- `aws_subnet`: Public × 2AZ、Private × 2AZ、Isolated × 2AZ（計6サブネット）
- `aws_internet_gateway`
- `aws_nat_gateway`: AZごとに1つ（高可用性のため）、EIPも生成
- `aws_route_table` + `aws_route_table_association`: サブネット種別ごとに分離

**VPC Endpoints**（CLAUDE.mdの一覧をすべて実装）
- S3: Gateway型
- ECR API, ECR DKR, Secrets Manager, STS, CloudWatch Logs: Interface型
- Interface型はPrivateサブネットに配置し、セキュリティグループを個別定義

**セキュリティグループ**
- `vpc_endpoint_sg`: VPC内からのHTTPS(443)のみ許可

### CIDR設計（CLAUDE.mdの設計を使用）

```
vpc_cidr       = "10.0.0.0/16"
public_cidrs   = ["10.0.0.0/24", "10.0.1.0/24"]
private_cidrs  = ["10.0.10.0/23", "10.0.12.0/23"]
isolated_cidrs = ["10.0.20.0/24", "10.0.21.0/24"]
```

### outputs.tf で必ず出力すること

`vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `isolated_subnet_ids`,
`vpc_cidr_block`, `nat_gateway_ids`

---

## Step 3: EKSモジュール生成

`terraform/modules/eks/` 配下の全ファイルを生成してください。

### クラスター設定

```hcl
# EKSバージョン: 1.29（変数化する）
# API Endpoint:
#   public_access  = true（CIDRで制限）
#   private_access = true
# public_access_cidrs: 変数で渡す（デフォルト: 自分のIPのみ）
# ログ: api, audit, authenticator, controllerManager, scheduler すべて有効
# 暗号化: aws_kms_key を作成しSecretsを暗号化
```

### Node Group設定

```hcl
# インスタンスタイプ: ["t3.medium", "t3.large"]（Karpenterと併用前提）
# 初期台数: desired=2, min=1, max=3
# サブネット: Privateサブネットのみ
# ディスク: gp3, 50GB
# AMI: AL2_x86_64（最新を自動取得）
```

### `irsa.tf` で以下のIRSAロールをすべて実装

| ロール名 | 用途 | 付与するポリシー |
|---|---|---|
| `tep-prod-karpenter` | Karpenterノード管理 | EC2フル（制限付き）, IAM PassRole |
| `tep-prod-lbc` | AWS Load Balancer Controller | ELB, EC2（制限付き） |
| `tep-prod-argocd` | ArgoCDのS3アーティファクト取得 | S3読み取り（特定バケットのみ） |
| `tep-prod-app` | サンプルアプリ用 | Secrets Manager読み取り（特定パスのみ） |

IRSAの実装パターン：
```hcl
# OIDC Providerを使ったIRSAの標準実装
# aws_iam_openid_connect_provider でEKSのOIDCエンドポイントを登録
# Trust PolicyのConditionにServiceAccountを明示的に指定
# StringEquals: "oidc.eks.ap-northeast-1.amazonaws.com/id/XXXX:sub"
#   = "system:serviceaccounts:{namespace}:{serviceaccount-name}"
```

### `aws-auth` ConfigMap

```hcl
# aws-auth ConfigMapをTerraformで管理する
# kubernetes_config_map_v1_data リソースを使用
# Node Group用ロールを必ず登録
# Karpenter用ノードロールも登録
```

---

## Step 4: Addonsモジュール生成

`terraform/modules/addons/` 配下の全ファイルを生成してください。

### AWS Load Balancer Controller

```hcl
# Helmチャート: aws/aws-load-balancer-controller
# バージョン: ~> 1.7
# ServiceAccountにIRSAロールをアノテーション
# clusterName, region, vpcId を values で渡す
```

### Karpenter

```hcl
# Helmチャート: oci://public.ecr.aws/karpenter/karpenter
# バージョン: ~> 0.35（変数化）
# SQS + EventBridge でスポットインスタンス中断通知を処理
# serviceAccount.annotations にIRSAロールを設定
```

### ArgoCD

```hcl
# Helmチャート: argo/argo-cd
# バージョン: ~> 6.0
# Server: LoadBalancer（ALBIngress）ではなく ClusterIP + Ingress
# admin初期パスワードはSecrets Managerに保存
# RBAC: project単位でアクセス制御
```

---

## Step 5: 可観測性モジュール生成

`terraform/modules/observability/` 配下の全ファイルを生成してください。

### CloudWatch Container Insights

```hcl
# amazon-cloudwatch-observability アドオンをEKSマネージドで有効化
# Node, Pod, Container レベルのメトリクスを収集
# IRSA: CloudWatchAgentServerPolicy を付与
```

### Amazon Managed Prometheus (AMP)

```hcl
# aws_prometheus_workspace を作成
# Prometheusサーバーをself-managedでEKSにデプロイ（Helmチャート）
# Remote writeエンドポイントをAMPに設定
# IRSA: AmazonPrometheusRemoteWriteAccess を付与
```

### Amazon Managed Grafana (AMG)

```hcl
# aws_grafana_workspace を作成
# 認証: AWS SSO（IAM Identity Center）
# データソース: PROMETHEUS, CLOUDWATCH を有効化
# ダッシュボードプロビジョニング: S3バケットからjson読み込み
```

---

## Step 6: Kubernetesマニフェスト生成

`kubernetes/` 配下の全ファイルを生成してください。

### `kubernetes/karpenter/node-pool.yaml`

```yaml
# NodePool: スポットインスタンス優先、オンデマンドフォールバック
# インスタンスファミリー: c5, m5, r5
# アーキテクチャ: amd64
# OS: bottlerocket（セキュリティ強化のため）
# 終了条件: 30分アイドルで自動削除
# EC2NodeClass: プライベートサブネット, セキュリティグループを参照
```

### `kubernetes/sample-app/`

```yaml
# Deployment:
#   replicas: 2（PodAntiAffinity で異なるNodeに分散）
#   resources: requests/limits を必ず設定
#   ServiceAccount: IRSA用のものをアノテーション付きで作成
#   securityContext: runAsNonRoot: true, readOnlyRootFilesystem: true
# Service: ClusterIP
# Ingress: ALB（aws-load-balancer-controller）、HTTPSリダイレクト設定
```

---

## Step 7: GitHub Actionsワークフロー生成

`.github/workflows/` 配下の全ファイルを生成してください。

### `terraform-plan.yml`

- トリガー: Pull Request（`terraform/` 配下の変更時のみ）
- 認証: OIDC（`aws-actions/configure-aws-credentials@v4`）
- ステップ: format check → init → validate → plan
- planの結果をPRコメントに投稿（`actions/github-script` 使用）

### `terraform-apply.yml`

- トリガー: `main` ブランチへのpush（`terraform/` 配下の変更時のみ）
- 認証: OIDC
- ステップ: init → apply（`-auto-approve`）
- apply後にSlack/Chatwork通知（Chatworkを使用すること）

---

## Step 8: ドキュメント生成

`docs/` 配下の全ファイルを生成してください。

### `docs/architecture.md`

- アーキテクチャ全体のMermaid図を含めること
- 各レイヤー（ネットワーク・コンピート・GitOps・可観測性）の説明
- 採用技術の選定理由（代替案との比較を含む）

### `docs/network-design.md`

- CIDR設計の意思決定ドキュメント
- VPC Endpointを使う理由（コスト・セキュリティの両面）
- 3層分離の設計思想（なぜIsolatedサブネットが必要か）

### `docs/cost-estimate.md`

- リソースごとの月次コスト試算（東京リージョン）
- コスト削減Tips（スポット活用、NAT Gateway削減、不要時のdestroy手順）
- `terraform destroy` の安全な実行手順

### `README.md`（ルート）

- プロジェクト概要
- 前提条件（AWS CLI, Terraform, kubectl, helm のバージョン）
- セットアップ手順（初回のみ必要な手動作業を明記）
- デプロイ手順（terraform init → plan → apply の順）
- 動作確認手順（kubectl get nodes でノード確認まで）

---

## 最終確認チェックリスト

生成完了後、以下を自己チェックしてください。

- [ ] CLAUDE.mdのディレクトリ構造と一致しているか
- [ ] すべてのTerraformファイルに `common_tags` が付与されているか
- [ ] 「なぜこの設定か」の日本語コメントがすべてのリソースにあるか
- [ ] ハードコードされた機密情報がないか（AWSアカウントID含む）
- [ ] `terraform.tfstate` が `.gitignore` に含まれているか
- [ ] IRSAロールのTrust PolicyにServiceAccount名が明示されているか
- [ ] VPC EndpointのInterface型にセキュリティグループが設定されているか
- [ ] EKS Public Endpoint の `public_access_cidrs` が `0.0.0.0/0` でないか
- [ ] Karpenterのスポットインスタンス中断ハンドリングが実装されているか
- [ ] GitHub ActionsのOIDC認証でアクセスキーを使っていないか

---

## 生成順序

以下の順序で生成してください（依存関係があるため）。

1. `README.md`, `.gitignore`
2. `terraform/environments/prod/backend.tf`, `terraform.tfvars.example`
3. `terraform/modules/vpc/` 全ファイル
4. `terraform/modules/eks/` 全ファイル（`irsa.tf` 含む）
5. `terraform/modules/addons/` 全ファイル
6. `terraform/modules/observability/` 全ファイル
7. `terraform/environments/prod/main.tf`, `variables.tf`, `outputs.tf`
8. `kubernetes/` 全ファイル
9. `.github/workflows/` 全ファイル
10. `docs/` 全ファイル