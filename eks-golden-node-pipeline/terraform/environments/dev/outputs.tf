output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value     = module.eks.cluster_endpoint
  sensitive = true
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "karpenter_irsa_arn" {
  value = module.eks.karpenter_irsa_arn
}

output "karpenter_node_instance_profile_name" {
  value = module.eks.karpenter_node_instance_profile_name
}

output "resolved_golden_ami_id" {
  description = "Karpenter EC2NodeClass に適用した Golden AMI ID"
  value       = module.karpenter.resolved_ami_id
}
