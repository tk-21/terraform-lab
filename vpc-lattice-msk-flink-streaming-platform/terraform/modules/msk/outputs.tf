output "msk_cluster_arn" {
  description = "MSK ServerlessクラスターのARN"
  value       = aws_msk_serverless_cluster.main.arn
}

output "msk_bootstrap_brokers_sasl_iam" {
  description = "MSK Serverless SASL/IAM認証用ブートストラップブローカーエンドポイント"
  value       = aws_msk_serverless_cluster.main.bootstrap_brokers_sasl_iam
}

output "msk_cluster_name" {
  description = "MSKクラスター名"
  value       = aws_msk_serverless_cluster.main.cluster_name
}
