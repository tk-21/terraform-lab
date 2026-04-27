output "cluster_name" {
  value = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  value = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  value = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.this.arn
}

output "node_group_role_arn" {
  value = aws_iam_role.node_group.arn
}

output "cluster_security_group_id" {
  value = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN for Karpenter-provisioned nodes"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_queue_url" {
  description = "SQS queue URL for Karpenter interruption handling"
  value       = aws_sqs_queue.karpenter.url
}
