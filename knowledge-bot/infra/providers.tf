# Terraform から AWS/EKS/OpenSearch を操作するための provider 設定。
provider "aws" {
  region = var.region
}

# Helm/Kubernetes provider 用に、EKS クラスタへ接続する一時トークンを取得する。
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
