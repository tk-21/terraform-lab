output "cluster_name" {
  description = "Name of the EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "API server endpoint of the EKS cluster"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "grafana_service_name" {
  description = "Kubernetes Service name for Grafana"
  value       = "grafana"
}

output "karpenter_queue_url" {
  description = "SQS queue URL used by Karpenter for node interruption handling"
  value       = module.eks.karpenter_queue_url
}
