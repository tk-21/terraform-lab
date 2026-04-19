# ✅Phase 5: Karpenter モジュール + Golden AMI EC2NodeClass

## 前フェーズの要約

Phase 1: ディレクトリ骨格・ベース設定ファイル
Phase 2: Ansible 3ロール（cis-benchmark / docker-runtime / eks-node-prep）
Phase 3: Packer Golden AMI テンプレート + GitHub Actions パイプライン
Phase 4: Terraform VPC / EKS モジュール（Karpenter 用 IRSA / Instance Profile を出力）

## このフェーズの目的

Karpenter を Helm でデプロイし、Golden AMI を参照する EC2NodeClass と NodePool を作成する。
これがこのプロジェクトの核心部分（Ansible × Packer × Karpenter の統合）。

Phase 3 で Packer がビルドした AMI ID を、EC2NodeClass の `amiSelectorTerms` で参照する。

---

## タスク一覧

### 1. Karpenter モジュール

**ファイル: `terraform/modules/karpenter/variables.tf`**

```hcl
variable "cluster_name" {
  description = "EKS クラスター名"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS クラスターエンドポイント"
  type        = string
}

variable "karpenter_version" {
  description = "Karpenter Helm チャートバージョン"
  type        = string
  default     = "0.37.0"
}

variable "karpenter_irsa_arn" {
  description = "Karpenter Controller の IRSA ARN（Phase 4 の EKS モジュール出力）"
  type        = string
}

variable "karpenter_node_instance_profile_name" {
  description = "Karpenter ノードの Instance Profile 名（Phase 4 の EKS モジュール出力）"
  type        = string
}

variable "karpenter_node_role_arn" {
  description = "Karpenter ノードの IAM Role ARN"
  type        = string
}

variable "private_subnet_ids" {
  description = "ノードを配置するプライベートサブネット ID リスト"
  type        = list(string)
}

variable "golden_ami_id" {
  description = "Phase 3 でビルドした Golden AMI の AMI ID。空文字の場合は AMI 名フィルタで検索"
  type        = string
  default     = ""
}

variable "eks_version" {
  description = "EKS バージョン（AMI 名フィルタで使用）"
  type        = string
  default     = "1.30"
}

variable "tags" {
  type    = map(string)
  default = {}
}
```

**ファイル: `terraform/modules/karpenter/main.tf`**

```hcl
# Karpenter モジュール
# Helm で Karpenter をデプロイし、Golden AMI を参照する EC2NodeClass を作成する

# Golden AMI を AMI ID 直接指定または名前フィルタで取得
data "aws_ami" "golden" {
  # golden_ami_id が指定されていない場合のフォールバック
  # Packer がビルドした AMI を名前で検索する
  count = var.golden_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["self"]  # 自アカウントのAMIのみ

  filter {
    name   = "name"
    values = ["golden-ami-eks-${var.eks_version}-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  # AMI ID の決定ロジック:
  # 1. 変数で直接指定された AMI ID があればそれを使う
  # 2. なければ Data Source で検索した最新の Golden AMI を使う
  resolved_ami_id = var.golden_ami_id != "" ? var.golden_ami_id : data.aws_ami.golden[0].id
}

# Karpenter Helm デプロイ
resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  values = [
    yamlencode({
      settings = {
        clusterName       = var.cluster_name
        clusterEndpoint   = var.cluster_endpoint
        interruptionQueue = aws_sqs_queue.karpenter_interruption.name
      }
      serviceAccount = {
        annotations = {
          # IRSA: Karpenter Controller に AWS 権限を付与
          "eks.amazonaws.com/role-arn" = var.karpenter_irsa_arn
        }
      }
      controller = {
        resources = {
          requests = {
            cpu    = "100m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }
      # ログレベル（debug は本番では info に変更）
      logLevel = "info"
    })
  ]

  depends_on = [aws_sqs_queue.karpenter_interruption]
}

# Spot インスタンス中断通知用 SQS キュー
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300  # 5分で削除

  tags = var.tags
}

# Spot 中断通知を SQS に転送するイベントルール
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-spot-interruption"
  description = "Karpenter: EC2 Spot 中断通知を SQS に転送"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EC2NodeClass: Golden AMI を参照するノード設定
# kubectl apply で適用するためにファイルとしてレンダリング
resource "local_file" "ec2_node_class" {
  filename = "${path.module}/templates/rendered-node-class.yaml"
  content = templatefile("${path.module}/templates/node-class.yaml", {
    cluster_name         = var.cluster_name
    ami_id               = local.resolved_ami_id
    instance_profile     = var.karpenter_node_instance_profile_name
    node_role_arn        = var.karpenter_node_role_arn
    eks_version          = var.eks_version
  })
}

# NodePool: ノードプロビジョニングポリシー
resource "local_file" "node_pool" {
  filename = "${path.module}/templates/rendered-node-pool.yaml"
  content = templatefile("${path.module}/templates/node-pool.yaml", {
    cluster_name = var.cluster_name
  })
}
```

**ファイル: `terraform/modules/karpenter/outputs.tf`**

```hcl
output "resolved_ami_id" {
  description = "Karpenter EC2NodeClass で使用する AMI ID"
  value       = local.resolved_ami_id
}

output "interruption_queue_name" {
  description = "Spot 中断通知用 SQS キュー名"
  value       = aws_sqs_queue.karpenter_interruption.name
}
```

---

### 2. EC2NodeClass テンプレート（Golden AMI 参照）

**ファイル: `terraform/modules/karpenter/templates/node-class.yaml`**

```yaml
# EC2NodeClass - Golden AMI を参照するノード設定
# このファイルは Terraform templatefile() でレンダリングされる
# ${ami_id} など ${} は Terraform 変数プレースホルダー

apiVersion: karpenter.k8s.aws/v1beta1
kind: EC2NodeClass
metadata:
  name: golden-ami-node-class
  annotations:
    # AMI の追跡情報（どのビルドの AMI か記録）
    eks-golden-node-pipeline/ami-id: "${ami_id}"
    eks-golden-node-pipeline/eks-version: "${eks_version}"
spec:
  # AMI の指定方法: ID 直接指定（Immutable AMI 原則）
  # latest タグや名前フィルタによる暗黙的な AMI 参照は禁止
  amiSelectorTerms:
    - id: "${ami_id}"

  # ノードの IAM Instance Profile
  instanceProfile: "${instance_profile}"

  # ノードを配置するサブネット（karpenter.sh/discovery タグで検索）
  subnetSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${cluster_name}"

  # セキュリティグループ（EKS ノードグループのセキュリティグループを使用）
  securityGroupSelectorTerms:
    - tags:
        karpenter.sh/discovery: "${cluster_name}"

  # ユーザーデータ: EKS ブートストラップスクリプトを実行
  # Golden AMI に amazon-eks-node パッケージがインストール済みのため
  # --apiserver-endpoint と --b64-cluster-ca のみ渡せばよい
  userData: |
    #!/bin/bash
    set -o xtrace
    /etc/eks/bootstrap.sh "${cluster_name}" \
      --use-max-pods false \
      --kubelet-extra-args '--node-labels=node.kubernetes.io/lifecycle=spot'

  # ルートボリューム設定
  blockDeviceMappings:
    - deviceName: /dev/xvda
      ebs:
        volumeSize: 30Gi
        volumeType: gp3
        encrypted: true
        deleteOnTermination: true
        iops: 3000
        throughput: 125

  # IMDSv2 強制（セキュリティ要件）
  metadataOptions:
    httpEndpoint: enabled
    httpPutResponseHopLimit: 1
    httpTokens: required

  # タグ
  tags:
    Project: eks-golden-node-pipeline
    ManagedBy: karpenter
    GoldenAMI: "${ami_id}"
```

**ファイル: `terraform/modules/karpenter/templates/node-pool.yaml`**

```yaml
# NodePool - ノードプロビジョニングポリシー
# スポットインスタンスを優先し、オンデマンドにフォールバックする

apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: golden-ami-node-pool
spec:
  template:
    metadata:
      labels:
        # ノード識別ラベル
        node-type: golden-ami
        cluster: "${cluster_name}"

    spec:
      # 使用する EC2NodeClass を参照
      nodeClassRef:
        apiVersion: karpenter.k8s.aws/v1beta1
        kind: EC2NodeClass
        name: golden-ami-node-class

      requirements:
        # アーキテクチャ: arm64 優先（Graviton でコスト削減）
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]

        # OS
        - key: kubernetes.io/os
          operator: In
          values: ["linux"]

        # インスタンスカテゴリ: t, m, c 系（汎用〜コンピュート最適化）
        - key: karpenter.k8s.aws/instance-category
          operator: In
          values: ["t", "m", "c"]

        # インスタンスサイズ: medium, large のみ
        - key: karpenter.k8s.aws/instance-size
          operator: In
          values: ["medium", "large"]

        # 容量タイプ: Spot 優先、オンデマンドフォールバック
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["spot", "on-demand"]

      # ノード有効期限（Golden AMI 更新を強制するため 7 日で入れ替え）
      expireAfter: 168h

  # スケールダウンポリシー
  disruption:
    consolidationPolicy: WhenUnderutilized
    consolidateAfter: 1m

  # ノード上限（コスト管理）
  limits:
    cpu: "32"
    memory: 64Gi
```

---

### 3. Karpenter を dev 環境に追加

**`terraform/environments/dev/main.tf` に以下を追記：**

```hcl
# Karpenter モジュール（既存の module "eks" の後に追加）
module "karpenter" {
  source = "../../modules/karpenter"

  cluster_name             = module.eks.cluster_name
  cluster_endpoint         = module.eks.cluster_endpoint
  karpenter_version        = var.karpenter_version
  karpenter_irsa_arn       = module.eks.karpenter_irsa_arn
  karpenter_node_instance_profile_name = module.eks.karpenter_node_instance_profile_name
  karpenter_node_role_arn  = module.eks.karpenter_node_role_arn
  private_subnet_ids       = module.vpc.private_subnet_ids

  # golden_ami_id を空にすると AMI 名フィルタで最新の Golden AMI を自動選択
  # CI/CD では packer-manifest.json から AMI ID を渡す
  golden_ami_id = var.golden_ami_id
  eks_version   = var.eks_version

  tags = local.common_tags
}
```

**`terraform/environments/dev/variables.tf` に以下を追記：**

```hcl
variable "karpenter_version" {
  type    = string
  default = "0.37.0"
}

variable "golden_ami_id" {
  description = "Golden AMI の AMI ID。空の場合は名前フィルタで最新版を自動選択"
  type        = string
  default     = ""
}
```

**`terraform/environments/dev/outputs.tf` に以下を追記：**

```hcl
output "resolved_golden_ami_id" {
  description = "Karpenter EC2NodeClass に適用した Golden AMI ID"
  value       = module.karpenter.resolved_ami_id
}
```

---

## 完了条件

- [ ] `terraform/modules/karpenter/main.tf` が存在する
- [ ] `terraform/modules/karpenter/variables.tf` が存在する
- [ ] `terraform/modules/karpenter/outputs.tf` が存在する
- [ ] `terraform/modules/karpenter/templates/node-class.yaml` が存在する
- [ ] `terraform/modules/karpenter/templates/node-pool.yaml` が存在する
- [ ] `terraform/environments/dev/main.tf` に karpenter モジュール呼び出しが追加されている
- [ ] `terraform validate` がエラーなく通過する

## 次フェーズへの引き継ぎ

Phase 6 では README.md、アーキテクチャドキュメント、ADR、Zenn 記事草稿を作成する。
全ファイルが揃った状態で GitHub 公開に向けた最終整備を行う。