# ✅Phase 2: Karpenter + Cell分割設計

## Phase 1 完了サマリー

- EKSクラスター `eks-chaos-cell-prod` 起動済み（ap-northeast-1）
- VPC: 10.0.0.0/16 / プライベートサブネット AZ-a(10.0.10.0/24)・AZ-c(10.0.11.0/24)
- Managed Node Group `system`: t4g.medium × 2台（AZ-a固定）
- `karpenter.sh/discovery=eks-chaos-cell-prod` タグがサブネット・SGに付与済み
- OIDC Provider ARN: `arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.ap-northeast-1.amazonaws.com/id/XXXX`

---

## このフェーズの目的

Karpenterを導入し、Cell-AとCell-Bそれぞれに専用NodePoolを作成する。
これがCell Architectureの核心で「AZをNodePoolで分離することで障害の非伝播を実現する」設計。

**面接で語れる設計判断**:
- なぜAZ分離だけでなくNodePool分離が必要か
- cluster-autoscalerではなくKarpenterを選んだ理由
- EC2NodeClassとNodePoolの責務分離

---

## 作成対象ファイル

### 1. terraform/modules/karpenter/main.tf

```hcl
# =============================================================
# Karpenter モジュール
# Cell-A（AZ-a専用）・Cell-B（AZ-c専用）のNodePoolを作成する
#
# 設計判断:
# - EC2NodeClass: AWSリソース（AMI・サブネット・SG）の定義
# - NodePool: スケーリングポリシー・ラベル・Taintの定義
# - NodePoolをCell単位で分けることでAZ障害が対向Cellに波及しない
# =============================================================

terraform {
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    helm = { source = "hashicorp/helm", version = "~> 2.0" }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}

# --- Karpenter コントローラー IAMロール（IRSA）---
# IRSAでNodeのIAMを借りずに直接EC2操作権限を取得する
resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-ctrl"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer}:sub" : "system:serviceaccount:karpenter:karpenter"
          "${var.oidc_issuer}:aud" : "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-policy"
  role = aws_iam_role.karpenter_controller.id

  # KarpenterのPublic EC2 Node Termination Handlerポリシー準拠
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplate",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:CreateTags",
          "ec2:TerminateInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeImages",
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ssm:GetParameter"
        ]
        Resource = "*"
      },
      # KarpenterがNodeに適用するIAMロールをPassできる権限
      {
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.node_group_role_arn
      },
      # スポットインスタンスのService-Linked Role作成
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/*"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = "spot.amazonaws.com"
          }
        }
      },
      # EKS クラスター情報取得
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${var.aws_account_id}:cluster/${var.cluster_name}"
      }
    ]
  })
}

# --- Karpenter Helm Chart インストール ---
resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.0.0"

  create_namespace = true

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller.arn
  }

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.clusterEndpoint"
    value = var.cluster_endpoint
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  # システムノードに配置（Karpenter管理ノードには乗せない）
  set {
    name  = "nodeSelector.node\\.kubernetes\\.io/purpose"
    value = "system"
  }

  depends_on = [aws_iam_role_policy.karpenter_controller]
}

# --- SQS（EC2 Spot中断通知用）---
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300  # 5分間保持

  tags = var.common_tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

# EventBridgeルール（Spot中断・スケジュールチェンジ）
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name = "${var.cluster_name}-spot-interruption"
  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule = aws_cloudwatch_event_rule.spot_interruption.name
  arn  = aws_sqs_queue.karpenter_interruption.arn
}

# --- EC2NodeClass: Cell-A（AZ-a 専用）---
resource "kubectl_manifest" "ec2nodeclass_cell_a" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: cell-a
    spec:
      # Graviton3 AL2 arm64 AMI を自動選択
      amiFamily: AL2
      amiSelectorTerms:
        - alias: al2@latest
      # AZ-a のサブネットのみ使用（Cell-A の核心設計）
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
            availability-zone: "ap-northeast-1a"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      role: "${var.node_group_role_name}"
      tags:
        Project: "${var.project_name}"
        Cell: "cell-a"
        # FIS実験ターゲットタグ
        chaos-target: "true"
        chaos-cell: "cell-a"
  YAML

  depends_on = [helm_release.karpenter]
}

# --- EC2NodeClass: Cell-B（AZ-c 専用）---
resource "kubectl_manifest" "ec2nodeclass_cell_b" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: cell-b
    spec:
      amiFamily: AL2
      amiSelectorTerms:
        - alias: al2@latest
      # AZ-c のサブネットのみ使用（Cell-B の核心設計）
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
            availability-zone: "ap-northeast-1c"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      role: "${var.node_group_role_name}"
      tags:
        Project: "${var.project_name}"
        Cell: "cell-b"
        chaos-target: "true"
        chaos-cell: "cell-b"
  YAML

  depends_on = [helm_release.karpenter]
}

# --- NodePool: Cell-A ---
resource "kubectl_manifest" "nodepool_cell_a" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cell-a
    spec:
      template:
        metadata:
          labels:
            cell: cell-a
            topology.kubernetes.io/zone: ap-northeast-1a
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: cell-a
          requirements:
            # AZ-a に固定
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["ap-northeast-1a"]
            # arm64（Graviton）優先・x86_64はフォールバック
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64", "amd64"]
            # On-Demand と Spot の混在（コスト最適化）
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand", "spot"]
            # 許可インスタンスファミリー
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - m7g.medium
                - m7g.large
                - m6g.medium
                - m6g.large
                - t4g.medium
                - t4g.large
          # システムノードには配置しない
          taints:
            - key: cell
              value: cell-a
              effect: NoSchedule
      limits:
        cpu: 20
        memory: 80Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 5m
  YAML

  depends_on = [kubectl_manifest.ec2nodeclass_cell_a]
}

# --- NodePool: Cell-B ---
resource "kubectl_manifest" "nodepool_cell_b" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: cell-b
    spec:
      template:
        metadata:
          labels:
            cell: cell-b
            topology.kubernetes.io/zone: ap-northeast-1c
        spec:
          nodeClassRef:
            group: karpenter.k8s.aws
            kind: EC2NodeClass
            name: cell-b
          requirements:
            - key: topology.kubernetes.io/zone
              operator: In
              values: ["ap-northeast-1c"]
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64", "amd64"]
            - key: karpenter.sh/capacity-type
              operator: In
              values: ["on-demand", "spot"]
            - key: node.kubernetes.io/instance-type
              operator: In
              values:
                - m7g.medium
                - m7g.large
                - m6g.medium
                - m6g.large
                - t4g.medium
                - t4g.large
          taints:
            - key: cell
              value: cell-b
              effect: NoSchedule
      limits:
        cpu: 20
        memory: 80Gi
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 5m
  YAML

  depends_on = [kubectl_manifest.ec2nodeclass_cell_b]
}
```

### 2. terraform/modules/karpenter/variables.tf

```hcl
variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "aws_region" { type = string; default = "ap-northeast-1" }
variable "aws_account_id" { type = string }
variable "project_name" { type = string }
variable "oidc_provider_arn" { type = string }
variable "oidc_issuer" { type = string }
variable "node_group_role_arn" { type = string }
variable "node_group_role_name" { type = string }
variable "common_tags" { type = map(string); default = {} }
```

### 3. terraform/modules/karpenter/outputs.tf

```hcl
output "karpenter_role_arn" { value = aws_iam_role.karpenter_controller.arn }
output "interruption_queue_name" { value = aws_sqs_queue.karpenter_interruption.name }
```

---

### 4. サブネットにAZ識別タグを追加

`terraform/modules/vpc/main.tf` のプライベートサブネットタグに追記する。

```hcl
# modules/vpc/main.tf の aws_subnet.private リソースのtags に以下を追加
tags = merge(var.common_tags, {
  Name = "${var.project_name}-private-${each.key}"
  "kubernetes.io/role/internal-elb"           = "1"
  "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  "karpenter.sh/discovery"                    = var.cluster_name
  # Karpenter EC2NodeClassがAZでサブネットを絞り込むためのタグ
  "availability-zone"                         = each.value.az
})
```

---

### 5. terraform/main.tf にKarpenterモジュールを追記

```hcl
# terraform/main.tf に追加

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
  load_config_file = false
}

module "karpenter" {
  source = "./modules/karpenter"

  cluster_name         = module.eks.cluster_name
  cluster_endpoint     = module.eks.cluster_endpoint
  aws_region           = var.aws_region
  aws_account_id       = var.aws_account_id
  project_name         = var.project_name
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_issuer          = replace(module.eks.cluster_oidc_issuer, "https://", "")
  node_group_role_arn  = module.eks.node_group_role_arn
  node_group_role_name = "${module.eks.cluster_name}-node-role"
  common_tags          = local.common_tags
}
```

---

### 6. 動作確認スクリプト

#### `scripts/verify_karpenter.sh`

```bash
#!/usr/bin/env bash
# Karpenter導入後の動作確認
set -euo pipefail

echo "📋 Karpenter Pod確認..."
kubectl get pods -n karpenter

echo ""
echo "📋 EC2NodeClass確認..."
kubectl get ec2nodeclass

echo ""
echo "📋 NodePool確認..."
kubectl get nodepool

echo ""
echo "📋 既存ノード確認..."
kubectl get nodes --show-labels | grep -E "NAME|cell"

echo ""
echo "🧪 Karpenterスケールテスト（Cell-A）..."
# Cell-AのTaintにTolerationを付けたテストPodをデプロイ
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: karpenter-test-cell-a
  namespace: default
spec:
  nodeSelector:
    cell: cell-a
  tolerations:
    - key: cell
      value: cell-a
      effect: NoSchedule
  containers:
    - name: test
      image: public.ecr.aws/amazonlinux/amazonlinux:2
      command: ["sleep", "60"]
      resources:
        requests:
          cpu: "1"
          memory: "512Mi"
EOF

echo "Pod作成済み。Karpenterがノードを起動するまで待機..."
kubectl wait --for=condition=Ready pod/karpenter-test-cell-a --timeout=300s
echo "✅ Cell-A ノード起動確認"

# クリーンアップ
kubectl delete pod karpenter-test-cell-a

echo ""
echo "✅ Karpenter動作確認完了"
```

---

## 実行手順

```bash
# terraform apply（Karpenter追加）
cd terraform
terraform init  # 新しいprovider（helm・kubectl）のため再init
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID" -var="owner=YOUR_NAME"

# 動作確認
chmod +x scripts/verify_karpenter.sh
./scripts/verify_karpenter.sh
```

---

## 完了確認チェックリスト

- [ ] `kubectl get pods -n karpenter` で karpenter Pod が `Running`
- [ ] `kubectl get ec2nodeclass` で `cell-a` と `cell-b` が表示される
- [ ] `kubectl get nodepool` で `cell-a` と `cell-b` が表示される
- [ ] `scripts/verify_karpenter.sh` でCell-Aのノードが300秒以内に起動する
- [ ] Cell-AノードのラベルにAZ-aが付いていることを確認

---

## 次フェーズへの引き継ぎ情報

Phase 3（ワークロード・PDB）では以下が前提となる。

- NodePool `cell-a`: AZ-a専用・Taint `cell=cell-a:NoSchedule`
- NodePool `cell-b`: AZ-c専用・Taint `cell=cell-b:NoSchedule`
- KarpenterはCell-AのPodをAZ-aに、Cell-BのPodをAZ-cに自動配置する
- システムノードラベル: `node.kubernetes.io/purpose=system`（Karpenter管理外）