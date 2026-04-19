# Karpenter モジュール
# Helm で Karpenter をデプロイし、Golden AMI を参照する EC2NodeClass を作成する

# golden_ami_id が指定されていない場合、AMI 名フィルタで最新の Golden AMI を取得
data "aws_ami" "golden" {
  count = var.golden_ami_id == "" ? 1 : 0

  most_recent = true
  owners      = ["self"]

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
  # AMI ID 決定ロジック:
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
      logLevel = "info"
    })
  ]

  depends_on = [aws_sqs_queue.karpenter_interruption]
}

# Spot インスタンス中断通知用 SQS キュー
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300

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

# EC2NodeClass テンプレートをレンダリングしてファイルに書き出す
resource "local_file" "ec2_node_class" {
  filename = "${path.module}/templates/rendered-node-class.yaml"
  content = templatefile("${path.module}/templates/node-class.yaml", {
    cluster_name     = var.cluster_name
    ami_id           = local.resolved_ami_id
    instance_profile = var.karpenter_node_instance_profile_name
    node_role_arn    = var.karpenter_node_role_arn
    eks_version      = var.eks_version
  })
}

# NodePool テンプレートをレンダリングしてファイルに書き出す
resource "local_file" "node_pool" {
  filename = "${path.module}/templates/rendered-node-pool.yaml"
  content = templatefile("${path.module}/templates/node-pool.yaml", {
    cluster_name = var.cluster_name
  })
}
