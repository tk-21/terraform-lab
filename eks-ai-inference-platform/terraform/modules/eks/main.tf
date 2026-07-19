locals {
  name_prefix = "${var.project}-${var.environment}"

  # Karpenterのリソース検出に使用するタグ値
  discovery_tag = "${var.project}-${var.environment}"

  # クラスター名: EKS APIでは名前をそのまま使うため変数化する
  cluster_name = "${local.name_prefix}-cluster"

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

# ────────────────────────────────────────────────
# EKS クラスターIAMロール
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  # 64文字制限: "eks-ai-inf-dev-cluster-role" = 27文字
  name               = "${local.name_prefix}-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ────────────────────────────────────────────────
# EKS クラスター セキュリティグループ
# ────────────────────────────────────────────────

resource "aws_security_group" "cluster" {
  name        = "${local.name_prefix}-cluster-sg"
  description = "EKSクラスターSG: VPC内443通信とノード間通信を許可"
  vpc_id      = var.vpc_id

  ingress {
    description = "VPC内からのKubernetes API"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # EKS APIエンドポイントはVPC内からのみアクセス許可する
    # VPC外からのアクセスは endpoint_public_access=false で遮断済み
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "全アウトバウンド許可"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cluster-sg"
    # KarpenterがクラスターSGを検出するために必要なタグ
    "karpenter.sh/discovery" = local.discovery_tag
  })
}

# ────────────────────────────────────────────────
# EKS クラスター
# ────────────────────────────────────────────────

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = var.cluster_version
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.cluster.id]
    # パブリックエンドポイントを無効化: VPC Endpoint経由のみでAPIサーバーにアクセスする
    endpoint_public_access  = false
    endpoint_private_access = true
  }

  # EKS コントロールプレーンのログは CloudWatch Logs に送信する
  # 障害調査とコンプライアンス要件の両方に対応するため全ログを有効化する
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  tags = merge(local.common_tags, {
    Name = local.cluster_name
  })

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# ────────────────────────────────────────────────
# OIDC プロバイダー (IRSA用)
# ────────────────────────────────────────────────

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  # EKS OIDCプロバイダーのthumbprintはAWSが管理するため変更不要
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-oidc"
  })
}

# ────────────────────────────────────────────────
# システムワークロード用 Managed Node Group (MNG)
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node_group" {
  # 64文字制限: "eks-ai-inf-dev-node-role" = 24文字
  name               = "${local.name_prefix}-node-role"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# SSM Session Manager経由でのデバッグアクセス用: bastionホストなしでノードに接続できる
resource "aws_iam_role_policy_attachment" "node_ssm_policy" {
  role       = aws_iam_role.node_group.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.name_prefix}-system"
  node_role_arn   = aws_iam_role.node_group.arn
  subnet_ids      = var.private_subnet_ids

  # c7g: Graviton3プロセッサー。arm64の最新世代でコスト対性能比が最高
  instance_types = [var.node_instance_type]

  ami_type = "BOTTLEROCKET_ARM_64"

  scaling_config {
    # システムワークロード(Karpenter, CoreDNS等)の可用性を確保するため最低2台を維持する
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-system-ng"
  })

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
    aws_iam_role_policy_attachment.node_ssm_policy,
  ]
}

# ────────────────────────────────────────────────
# EKS Add-ons
# ────────────────────────────────────────────────

# Add-onはfor_eachで管理するが、ebs-csi-driverはservice_account_role_arnが必要なため個別定義する
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "vpc-cni"

  tags = local.common_tags

  # MNGが作成された後でないとAdd-onのインストールに失敗する
  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  tags = local.common_tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"
  # EBS CSI DriverはIRSAによる権限付与が必要なため、専用ロールのARNを指定する
  service_account_role_arn = aws_iam_role.ebs_csi_controller.arn

  tags = local.common_tags

  depends_on = [aws_eks_node_group.system]
}

# ────────────────────────────────────────────────
# Karpenter用 SQS キュー (Spot中断通知)
# ────────────────────────────────────────────────

resource "aws_sqs_queue" "karpenter" {
  # Spot中断通知を受け取りKarpenterがGraceful Drainを実行するためのキュー
  # 中断通知からノード終了まで約2分しかないため、メッセージは即時処理される
  name                      = "${local.name_prefix}-karpenter"
  message_retention_seconds = 300
  # SQSメッセージを静止状態で暗号化するため
  sqs_managed_sse_enabled = true

  tags = local.common_tags
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "karpenter_sqs" {
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter" {
  queue_url = aws_sqs_queue.karpenter.url
  policy    = data.aws_iam_policy_document.karpenter_sqs.json
}

# Spot中断通知を検知するEventBridgeルール
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${local.name_prefix}-karpenter-spot"
  description = "KarpenterへのSpot中断通知転送用"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_sqs" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "KarpenterSQS"
  arn       = aws_sqs_queue.karpenter.arn
}

# ────────────────────────────────────────────────
# Karpenterコントローラー IRSA
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  # 64文字制限: "eks-ai-inf-dev-karpenter-ctrl" = 29文字
  name               = "${local.name_prefix}-karpenter-ctrl"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2インスタンスのプロビジョニングに必要な最小権限
  # ec2:Describe* および RunInstances は AWS APIの仕様上リソースARNによる絞り込みが不可能なため
  # resources = ["*"] を使用する (参照: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html)
  statement {
    effect = "Allow"
    actions = [
      "ec2:CreateLaunchTemplate",
      "ec2:CreateFleet",
      "ec2:RunInstances",
      "ec2:CreateTags",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeSpotPriceHistory",
    ]
    resources = ["*"]
  }

  # pricing:GetProducts は AWS Pricing API の仕様上リソースARN制限が不可能なため resources = ["*"]
  # Spot価格情報を取得してコスト最適なインスタンスタイプを選択するため
  statement {
    effect    = "Allow"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # Spot中断通知キューからメッセージを取得してGraceful Drainを実行するため
  statement {
    effect = "Allow"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]
    resources = [aws_sqs_queue.karpenter.arn]
  }

  # Karpenterがノードに付与するIAMロールをEC2に渡すために必要
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  # Karpenterがクラスター情報を取得してノードプロビジョニングを最適化するため
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "${local.name_prefix}-karpenter-ctrl-policy"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

# ────────────────────────────────────────────────
# Karpenter Node IAMロール
# ────────────────────────────────────────────────

resource "aws_iam_role" "karpenter_node" {
  # 64文字制限: "eks-ai-inf-dev-karpenter-node" = 29文字
  name               = "${local.name_prefix}-karpenter-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# ────────────────────────────────────────────────
# AWS Load Balancer Controller IRSA
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  # 64文字制限: "eks-ai-inf-dev-alb-ctrl" = 23文字
  name               = "${local.name_prefix}-alb-ctrl"
  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "alb_controller" {
  # AWS Load Balancer Controller の公式推奨ポリシーに準拠する
  # elasticloadbalancing:Describe*/ec2:Describe* はAWS APIの仕様上リソースARN制限が不可のため
  # resources = ["*"] を使用する (AWS公式: https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
  statement {
    effect = "Allow"
    actions = [
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DeleteSecurityGroup",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "cognito-idp:DescribeUserPoolClient",
      "acm:ListCertificates",
      "acm:DescribeCertificate",
      "iam:ListServerCertificates",
      "iam:GetServerCertificate",
      "waf-regional:GetWebACL",
      "waf-regional:GetWebACLForResource",
      "waf-regional:AssociateWebACL",
      "waf-regional:DisassociateWebACL",
      "wafv2:GetWebACL",
      "wafv2:GetWebACLForResource",
      "wafv2:AssociateWebACL",
      "wafv2:DisassociateWebACL",
      "shield:GetSubscriptionState",
      "shield:DescribeProtection",
      "shield:CreateProtection",
      "shield:DeleteProtection",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "alb_controller" {
  name   = "${local.name_prefix}-alb-ctrl-policy"
  role   = aws_iam_role.alb_controller.id
  policy = data.aws_iam_policy_document.alb_controller.json
}

# ────────────────────────────────────────────────
# EBS CSI Controller IRSA
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "ebs_csi_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${aws_iam_openid_connect_provider.eks.url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_controller" {
  # 64文字制限: "eks-ai-inf-dev-ebs-csi-ctrl" = 27文字
  name               = "${local.name_prefix}-ebs-csi-ctrl"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume_role.json

  tags = local.common_tags
}

# vLLMモデルキャッシュ用EBSボリュームの作成・管理に必要な権限
resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi_controller.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}
