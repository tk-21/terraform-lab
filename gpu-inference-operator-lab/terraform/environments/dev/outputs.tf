output "cluster_name" {
  description = "EKSクラスタ名"
  value       = module.eks.cluster_name
}

output "operator_role_arn" {
  description = "OperatorのIRSAロールARN (Kubernetes ServiceAccountアノテーションに設定する)"
  value       = module.iam.operator_role_arn
}

output "gpu_nodepool_name" {
  description = "GPU推論用NodePool名 (AIInferenceServiceのgpuNodePoolRefに設定する値)"
  value       = module.karpenter.gpu_nodepool_name
}

output "kubeconfig_command" {
  description = "kubeconfigを更新するコマンド"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ap-northeast-1"
}
