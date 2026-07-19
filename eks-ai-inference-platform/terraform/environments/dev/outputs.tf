output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "cluster_name" {
  description = "EKSクラスター名"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS APIエンドポイント"
  value       = module.eks.cluster_endpoint
}

output "karpenter_irsa_arn" {
  description = "KarpenterコントローラーIRSAロールARN"
  # KarpenterのIRSAロールはeksモジュールで管理しているため、eksモジュールのoutputを直接参照する
  value = module.eks.karpenter_controller_irsa_arn
}

output "model_cache_bucket_name" {
  description = "vLLMモデルキャッシュS3バケット名 (upload_model_to_s3.sh の BUCKET_NAME に使用)"
  value       = module.eks.model_cache_bucket_name
}

output "vllm_irsa_role_arn" {
  description = "vLLM IRSAロールARN (k8s/vllm/serviceaccount.yaml のアノテーションに設定)"
  value       = module.eks.vllm_irsa_role_arn
}

output "amp_workspace_id" {
  description = "AMPワークスペースID"
  value       = module.observability.amp_workspace_id
}

output "amp_remote_write_url" {
  description = "AMP remote_write URL (OTEL Collector Secretに設定する)"
  value       = module.observability.amp_remote_write_url
}

output "otel_collector_irsa_arn" {
  description = "OTEL Collector IRSAロールARN (k8s/otel/serviceaccount.yaml のアノテーションに設定)"
  value       = module.observability.otel_collector_irsa_arn
}

output "amg_workspace_url" {
  description = "Grafanaダッシュボードの接続URL"
  value       = module.observability.amg_workspace_url
}

output "ecr_repository_url" {
  description = "AI Gateway ECR リポジトリ URL (docker build/push コマンドで使用)"
  value       = module.gateway.ecr_repository_url
}

output "gateway_irsa_role_arn" {
  description = "AI Gateway IRSA ロール ARN (k8s/gateway/serviceaccount.yaml の GATEWAY_IRSA_ROLE_ARN に設定)"
  value       = module.gateway.gateway_irsa_role_arn
}

output "cloudwatch_alarm_name" {
  description = "推論コスト超過アラーム名"
  value       = module.gateway.cloudwatch_alarm_name
}
