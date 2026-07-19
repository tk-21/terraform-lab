# =============================================================================
# EKS Container Insights — Pod Identity + アドオン
# =============================================================================
# ECS は Phase 2 で Container Insights 有効化済み。
# EKS 側は amazon-cloudwatch-observability アドオンで同等の可観測性を確保する。

# CloudWatch Agent 用 IAM ロール
# Pod Identity 方式: OIDC IRSA と異なり OIDC Provider の設定が不要
resource "aws_iam_role" "cloudwatch_agent" {
  # "deepdive-eks-cw-agent" = 22文字 (64文字制限内)
  name               = "deepdive-eks-cw-agent"
  assume_role_policy = local.pod_identity_trust_policy

  tags = {
    Phase = "4"
  }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role = aws_iam_role.cloudwatch_agent.name
  # AWSマネージドポリシー: CloudWatch Logs・Metrics書き込みの最小権限セット
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# Pod Identity Association: cloudwatch-agent ServiceAccount にロールをバインド
# アドオンが amazon-cloudwatch namespace に cloudwatch-agent SA を自動生成する
resource "aws_eks_pod_identity_association" "cloudwatch_agent" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "amazon-cloudwatch"
  service_account = "cloudwatch-agent"
  role_arn        = aws_iam_role.cloudwatch_agent.arn

  # ロールが存在してからアソシエーションを作成する
  depends_on = [aws_iam_role_policy_attachment.cloudwatch_agent]
}

# amazon-cloudwatch-observability アドオン
# Container Insights (メトリクス) + CloudWatch Logs (ログ) を一括セットアップ
resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "amazon-cloudwatch-observability"

  # Pod Identity Association が先に存在する必要がある
  # アドオンが SA を作成した瞬間にロールバインドが有効になるため
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_pod_identity_association.cloudwatch_agent,
    aws_eks_node_group.system,
    aws_eks_addon.addons,
  ]

  tags = {
    Phase = "4"
  }
}
