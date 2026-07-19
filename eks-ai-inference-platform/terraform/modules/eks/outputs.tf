output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca_certificate" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "oidc_provider_arn" {
  value = aws_iam_openid_connect_provider.eks.arn
}

output "oidc_provider_url" {
  value = aws_iam_openid_connect_provider.eks.url
}

output "karpenter_node_role_arn" {
  value = aws_iam_role.karpenter_node.arn
}

output "karpenter_node_role_name" {
  value = aws_iam_role.karpenter_node.name
}

output "karpenter_queue_arn" {
  value = aws_sqs_queue.karpenter.arn
}

output "karpenter_queue_url" {
  value = aws_sqs_queue.karpenter.url
}

output "karpenter_controller_irsa_arn" {
  value = aws_iam_role.karpenter_controller.arn
}

output "model_cache_bucket_name" {
  description = "vLLMモデルキャッシュS3バケット名"
  value       = aws_s3_bucket.model_cache.bucket
}

output "vllm_irsa_role_arn" {
  description = "vLLM IRSA ロールARN (serviceaccount.yamlのアノテーションに設定)"
  value       = aws_iam_role.vllm_irsa.arn
}
