# ✅Phase 1: VPC・EKS基盤構築

## このフェーズの概要

eks-chaos-postmortem-generatorプロジェクトのPhase 1。
VPCとEKSクラスターをTerraformで構築する。

## プロジェクト全体の設計（必ず読むこと）

CLAUDE.mdを読み、以下を把握してから実装を開始すること：
- ディレクトリ構造
- 命名規則（例: EKSクラスター名 = `eks-chaos-postmortem-dev`）
- タグ戦略（5タグ必須）
- 禁止パターン

## Phase 1で実装するもの

### 1. Terraform バックエンド・プロバイダー設定

`terraform/main.tf` に以下を実装：
- terraform required_version: >= 1.6
- required_providers: aws (~> 5.0), kubernetes (~> 2.0), helm (~> 2.0)
- backend "s3"（バケット名・キーはvariablesで管理）
- provider "aws" region = var.region

`terraform/variables.tf` に以下を定義：
- project（default: "eks-chaos-postmortem-generator"）
- environment（default: "dev"）
- region（default: "ap-northeast-1"）
- aws_account_id

`terraform/environments/dev/terraform.tfvars` を作成：
- region = "ap-northeast-1"
- environment = "dev"

---

### 2. VPCモジュール（terraform/modules/vpc/）

`main.tf` に以下を実装：
- VPC CIDR: 10.0.0.0/16
- パブリックサブネット×2（ap-northeast-1a, 1c）: 10.0.1.0/24, 10.0.2.0/24
- プライベートサブネット×2（ap-northeast-1a, 1c）: 10.0.11.0/24, 10.0.12.0/24
- Internet Gateway
- NAT Gateway（パブリックサブネットに1つ、コスト削減のため1AZ）
- ルートテーブル（パブリック・プライベート各1つ）
- EKS用サブネットタグ（必須）:
  - パブリック: `kubernetes.io/role/elb = 1`
  - プライベート: `kubernetes.io/role/internal-elb = 1`
  - 全サブネット: `kubernetes.io/cluster/{cluster_name} = shared`

---

### 3. EKSモジュール（terraform/modules/eks/）

`main.tf` に以下を実装：

**EKSクラスター**:
- クラスター名: `${var.project}-${var.environment}` → `eks-chaos-postmortem-dev`
- Kubernetes version: 1.30
- エンドポイント: パブリック（devのみ許可。本番禁止を日本語コメントで明記）
- サブネット: プライベートサブネット両AZ
- クラスターロールARN: 新規作成するIAMロール

**マネージドノードグループ（ベースライン用）**:
- 名前: `${var.project}-baseline-${var.environment}`
- インスタンスタイプ: t3.medium
- 希望台数: 2、最小: 1、最大: 4
- AMIタイプ: AL2_x86_64
- タグ: `ChaosTarget=false`（ベースラインノードはFIS対象外）

**Chaosターゲット用ノードグループ**:
- 名前: `${var.project}-chaos-${var.environment}`
- インスタンスタイプ: t3.medium
- 希望台数: 2、最小: 1、最大: 4
- タグ: `ChaosTarget=true`（FIS実験の対象ノード）
- ラベル: `role=chaos-target`

**アドオン（EKSマネージド）**:
- vpc-cni
- coredns
- kube-proxy
- aws-ebs-csi-driver（IRSAで認証）

**IRSA（IAM Roles for Service Accounts）**:
- EBSCSIドライバー用IRSAロールを作成
- OIDCプロバイダーをTerraformで管理

---

### 4. サンプルアプリ（k8s/sample-app/）

FIS実験の対象となるサンプルアプリのマニフェストを作成：

`namespace.yaml`:
```yaml
# chaos-targetネームスペース: FIS実験の対象namespace
# このnamespaceのリソースのみにChaos Engineeringを適用する
apiVersion: v1
kind: Namespace
metadata:
  name: chaos-target
  labels:
    chaos-enabled: "true"
```

`deployment.yaml`:
- nginx:1.25ベースのDeployment
- replicas: 3
- namespace: chaos-target
- nodeSelector: role=chaos-target
- リソースリクエスト/リミット設定（CPUストレステスト検知のため必須）
- ラベル: `app=sample-app`, `chaos-target=true`

---

### 5. GitHub Actions（.github/workflows/）

`terraform-plan.yml`:
- トリガー: pull_request
- OIDC認証（aws-actions/configure-aws-credentials@v4）
- terraform fmt, validate, plan
- planの結果をPRコメントに投稿

`terraform-apply.yml`:
- トリガー: push to main
- OIDC認証
- terraform apply -auto-approve

---

## 実装上の注意事項

1. **全リソースにタグを付与**（CLAUDE.mdのタグ戦略参照）
2. **日本語インラインコメント**でTerraformの設計意図を説明する
   - 例: `# カオスエンジニアリング対象ノード - FIS実験はこのノードグループのみに適用する`
3. **outputs.tf**でEKSクラスター名・エンドポイント・OIDCプロバイダーURLを出力する
4. `terraform/environments/dev/main.tf`でmodule呼び出しを実装する
5. Karpenterはこのフェーズでは**実装しない**（Phase 2で追加）

## 完了確認

以下のファイルが生成されていることを確認：
- [ ] terraform/main.tf
- [ ] terraform/variables.tf
- [ ] terraform/outputs.tf
- [ ] terraform/modules/vpc/main.tf, variables.tf, outputs.tf
- [ ] terraform/modules/eks/main.tf, variables.tf, outputs.tf
- [ ] terraform/environments/dev/main.tf, variables.tf, terraform.tfvars
- [ ] k8s/sample-app/namespace.yaml
- [ ] k8s/sample-app/deployment.yaml
- [ ] .github/workflows/terraform-plan.yml
- [ ] .github/workflows/terraform-apply.yml
- [ ] CLAUDE.mdのディレクトリ構造と一致していること