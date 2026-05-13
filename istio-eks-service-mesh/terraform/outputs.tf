output "eks_cluster_name" {
  description = "EKSクラスタ名"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS APIエンドポイントURL"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_certificate_authority_data" {
  description = "EKSクラスタのCA証明書データ（base64エンコード）"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "eks_node_role_arn" {
  description = "EKSワーカーノードIAMロールARN"
  value       = module.iam.eks_node_role_arn
}

output "report_bucket_name" {
  description = "S3レポートバケット名"
  value       = module.s3.bucket_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト"
  value       = module.vpc.private_subnet_ids
}
