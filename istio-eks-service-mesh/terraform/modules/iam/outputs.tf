output "eks_cluster_role_arn" {
  description = "EKSクラスタIAMロールARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "eks_node_role_arn" {
  description = "EKSワーカーノードIAMロールARN"
  value       = aws_iam_role.eks_node.arn
}

output "github_actions_role_arn" {
  description = "GitHub Actions OIDCロールARN"
  value       = aws_iam_role.github_actions.arn
}
