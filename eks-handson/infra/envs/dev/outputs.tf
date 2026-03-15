output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = var.aws_region
}

output "oidc_provider_arn" {
  value = module.eks.oidc_provider_arn
}
