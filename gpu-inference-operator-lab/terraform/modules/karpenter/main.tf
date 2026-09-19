data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# Karpenter自体のIAMロール (IRSA)
# SQS/EC2/IAM PassRoleなどKarpenterがノードを管理するために必要な権限
resource "aws_iam_role" "karpenter" {
  # 64文字制限: "giop-dev-karpenter-role" = 23文字 (余裕あり)
  name = "${local.name_prefix}-karpenter-role"

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
          # Karpenter ServiceAccountのOIDC subjectを制限する
          "${replace(var.oidc_provider_arn, "/^.*provider//", "")}:sub" = "system:serviceaccount:karpenter:karpenter"
          "${replace(var.oidc_provider_arn, "/^.*provider//", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "karpenter" {
  name = "${local.name_prefix}-karpenter-policy"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2インスタンスの起動・終了権限 (GPUノードのスケジューリングに必要)
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
        ]
        # ec2:Describe* はIAMリソースレベル権限が非対応のためAWS側の制約で * が必須
        # リージョン条件で ap-northeast-1 に限定してリスクを最小化する
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:RequestedRegion" = data.aws_region.current.name
          }
        }
      },
      {
        # KarpenterがEC2にIAMロールを渡すために必要 (NodeRole)
        # ワイルドカードではなく特定のNodeRoleARNに限定する
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.node_role_arn
      },
      {
        # Spot中断通知をSQSで受け取るために必要
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        # EKSノードグループとクラスタの情報取得
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:DescribeNodegroup",
        ]
        Resource = "arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"
      },
    ]
  })
}

# Spot中断通知用SQSキュー
# Karpenter v0.32以降はSQSでSpot中断通知を受け取りPodをGracefully Drainする
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${local.name_prefix}-karpenter-interruption"
  message_retention_seconds = 300

  tags = local.common_tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# EventBridgeルール: Spot中断・スケジュール変更をSQSに転送する
resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${local.name_prefix}-karpenter-spot-interruption"
  description = "Spotインスタンスの中断通知をKarpenterのSQSキューに転送する"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Karpenter HelmチャートのインストールはTerraformのhelm providerで管理する
# helmfileやArgoCD等は使わず、インフラ定義と同一リポジトリで管理することで
# インフラと設定の一貫性を保つ
resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version

  set {
    name  = "settings.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter.arn
  }

  set {
    # arm64ノードにKarpenter自体をスケジュールする
    name  = "nodeSelector.kubernetes\\.io/arch"
    value = "arm64"
  }

  depends_on = [aws_iam_role_policy.karpenter]
}

# GPU推論用 EC2NodeClass: g5gインスタンス向けのAMI・サブネット設定
resource "kubectl_manifest" "gpu_node_class" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1beta1
    kind: EC2NodeClass
    metadata:
      name: gpu-g5g
    spec:
      # Graviton2 + NVIDIA T4G GPU用のEKS最適化AMI (arm64)
      # amiFamily: AL2はAmazon Linux 2 EKS最適化AMIを自動選択する
      amiFamily: AL2
      role: "${var.node_role_arn}"
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: "${var.cluster_name}"
      tags:
        ManagedBy: terraform
        Project: "${var.prefix}"
  YAML

  depends_on = [helm_release.karpenter]
}

# GPU推論用 NodePool: g5g系(Graviton2 + T4G)のSpot優先設定
resource "kubectl_manifest" "gpu_node_pool" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1beta1
    kind: NodePool
    metadata:
      name: ${var.gpu_nodepool_name}
    spec:
      template:
        metadata:
          labels:
            karpenter.sh/nodepool: "${var.gpu_nodepool_name}"
            node-role: gpu-inference
        spec:
          nodeClassRef:
            apiVersion: karpenter.k8s.aws/v1beta1
            kind: EC2NodeClass
            name: gpu-g5g
          requirements:
            # Graviton2 + T4G GPU: arm64アーキテクチャに統一
            - key: kubernetes.io/arch
              operator: In
              values: ["arm64"]
            - key: karpenter.k8s.aws/instance-family
              operator: In
              # g5g: Graviton2 + NVIDIA T4G (arm64)
              # x86_64のg4dn/g5よりコスト効率が高い (同スループットで約20-30%安価)
              values: ["g5g"]
            - key: karpenter.k8s.aws/instance-size
              operator: In
              # xlarge(1GPU)とmedium(テスト用)のみ許可してコスト上限を制御する
              values: ["medium", "xlarge", "2xlarge"]
            - key: karpenter.sh/capacity-type
              operator: In
              # Spot優先: GPU推論は定常負荷ではないためSpotで十分
              # On-Demandより最大70%安価。中断時はBedrockフォールバックで吸収する
              values: ["spot", "on-demand"]
      disruption:
        consolidationPolicy: WhenUnderutilized
        # GPUノードのコールドスタートが長いため、最低5分は維持する
        consolidateAfter: 5m
      # コスト暴走防止: GPUノードは最大8台まで
      limits:
        cpu: "64"
        memory: 256Gi
        "nvidia.com/gpu": "8"
  YAML

  depends_on = [kubectl_manifest.gpu_node_class]
}
