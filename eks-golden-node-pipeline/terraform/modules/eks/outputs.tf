output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  value = module.eks.cluster_certificate_authority_data
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}

output "karpenter_irsa_arn" {
  description = "Karpenter Controller の IRSA ARN"
  value       = module.karpenter_irsa.iam_role_arn
}

output "karpenter_node_instance_profile_name" {
  description = "Karpenter が EC2 起動時に使用する Instance Profile 名"
  value       = aws_iam_instance_profile.karpenter_node.name
}

output "karpenter_node_role_arn" {
  description = "Karpenter ノードの IAM Role ARN"
  value       = aws_iam_role.karpenter_node.arn
}
