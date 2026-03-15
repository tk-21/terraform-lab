provider "aws" {
  region = var.region
}

data "aws_eks_cluster_auth" "lbc" {
  count = var.enable_lbc ? 1 : 0
  name  = module.eks.cluster_name
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = var.enable_lbc ? data.aws_eks_cluster_auth.lbc[0].token : ""
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = var.enable_lbc ? data.aws_eks_cluster_auth.lbc[0].token : ""
  }
}

provider "opensearch" {
  url         = aws_opensearchserverless_collection.kb.collection_endpoint
  aws_region  = var.region
  healthcheck = false
}
