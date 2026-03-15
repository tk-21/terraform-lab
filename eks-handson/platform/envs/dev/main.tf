# --- 重要：ALB Controller 用 IRSA（ここは確実に動く定番）---
data "aws_iam_openid_connect_provider" "this" {
  # infra で作られた OIDC を参照（EKS moduleが作っている想定）
  url = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
}

module "alb_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.cluster_name}-alb-controller"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn = data.aws_iam_openid_connect_provider.this.arn
      namespace_service_accounts = [
        "kube-system:aws-load-balancer-controller"
      ]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"

  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.7.2"

  set {
    name = "clusterName"
    value = var.cluster_name
  }

  set {
    name = "region"
    value = var.aws_region
  }

  set {
    name = "serviceAccount.create"
    value = "true"
  }

  set {
    name = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.alb_controller_irsa.iam_role_arn
  }

  timeout = 900
}

# --- Argo CD（GitOps）---
resource "kubernetes_namespace" "argocd" {
  metadata { name = "argocd" }
}

# 「起動直後で endpoints が 0」だと、Helm/terraform が先に走ってコケます。platform 側で ArgoCD の前に 待ちを入れる
resource "null_resource" "wait_alb_webhook" {
  provisioner "local-exec" {
    command = <<EOT
set -e
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m
kubectl -n kube-system get endpoints aws-load-balancer-webhook-service -o jsonpath='{.subsets[0].addresses[0].ip}' >/dev/null
EOT
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "6.7.18"

  set {
    name = "server.service.type"
    value = "ClusterIP"
  }

  timeout = 900
}
