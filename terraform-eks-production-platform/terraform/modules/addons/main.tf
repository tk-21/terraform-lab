################################################################################
# Addonsモジュール - ArgoCD / AWS Load Balancer Controller / Karpenter
################################################################################

################################################################################
# HelmプロバイダーとKubernetesプロバイダーの設定
# Addonsモジュール内でHelmとKubernetesリソースを管理するためのプロバイダー設定
################################################################################

terraform {
  required_providers {
    htpasswd = {
      source  = "loafoe/htpasswd"
      version = "~> 1.0"
    }
  }
}

################################################################################
# AWS Load Balancer Controller
#
# Kubernetes IngressリソースからALBを自動プロビジョニングする。
# ALBの作成・設定・削除をKubernetesネイティブな方法で管理できる。
# LBCを使う理由：
# NLBより豊富なHTTP機能（パスルーティング・ヘッダー操作等）が使える。
# Ingressアノテーションで細かく設定可能。
################################################################################

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  # バージョンを固定する理由：
  # ~> 1.7 の形式で指定するとパッチバージョンの自動更新ができる。
  # ただし本番では完全固定も検討する。
  version = "~> 1.7"

  values = [
    yamlencode({
      # クラスター名の指定（ALBがどのクラスターに属するかの識別）
      clusterName = var.cluster_name

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          # IRSAロールをServiceAccountに設定
          "eks.amazonaws.com/role-arn" = var.lbc_irsa_role_arn
        }
      }

      # リージョンとVPC IDを指定することでサブネット検索の精度が向上する
      region = var.aws_region
      vpcId  = var.vpc_id

      # 高可用性のため2つのレプリカを配置
      # LBCが停止するとIngressの更新ができなくなるため最低2つ必要
      replicaCount = 2

      # PodDisruptionBudgetで最低1つは常時稼働させる
      podDisruptionBudget = {
        maxUnavailable = 1
      }
    })
  ]
}

################################################################################
# Karpenter
#
# ノードの自動プロビジョニングツール。Cluster Autoscalerより高速で
# スポットインスタンスの活用が容易なためKarpenterを採用。
#
# Karpenter vs Cluster Autoscaler 比較：
# - Karpenter: Pod要求を直接見てノードをプロビジョニング（秒単位で起動）
# - CA: Node Groupのスケーリングに依存（分単位）
################################################################################

resource "helm_release" "karpenter" {
  name      = "karpenter"
  # Karpenter公式レジストリ（ECR Public）
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  namespace  = "karpenter"
  version    = var.karpenter_version

  # Namespaceが存在しない場合は自動作成
  create_namespace = true

  values = [
    yamlencode({
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.karpenter_irsa_role_arn
        }
      }

      settings = {
        # Karpenterが管理するクラスターの識別
        clusterName = var.cluster_name

        # スポットインスタンス中断通知を受け取るSQSキュー名
        # これを設定しないとスポット中断時のドレインが機能しない
        interruptionQueue = var.karpenter_sqs_queue_name
      }

      controller = {
        resources = {
          requests = {
            cpu    = "500m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "1"
            memory = "1Gi"
          }
        }
      }

      # 高可用性のため2つのレプリカを配置
      replicas = 2

      # PodAntiAffinityでKarpenterコントローラー自体のPodを異なるノードに分散
      # Karpenterが停止するとノードのプロビジョニングができなくなるため重要
      affinity = {
        podAntiAffinity = {
          requiredDuringSchedulingIgnoredDuringExecution = [{
            topologyKey = "kubernetes.io/hostname"
            labelSelector = {
              matchLabels = {
                "app.kubernetes.io/name" = "karpenter"
              }
            }
          }]
        }
      }
    })
  ]
}

################################################################################
# ArgoCD
#
# GitOpsのデリバリーツール。Gitリポジトリをソースオブトゥルースとして
# Kubernetesクラスターの状態を自動同期する。
#
# ArgoCD vs Flux 比較：
# - ArgoCD: UIが充実、マルチクラスター管理が容易
# - Flux: より軽量、GitOpsに特化
# UIでの可視性を重視してArgoCDを採用。
################################################################################

# ArgoCDのadmin初期パスワードをSecrets Managerに保存する。
# ハードコードしてリポジトリにコミットすることを防ぐ。
resource "random_password" "argocd_admin" {
  length  = 24
  special = true
}

resource "aws_secretsmanager_secret" "argocd_admin" {
  name        = "${var.project_name}/${var.environment}/argocd-admin-password"
  description = "ArgoCD管理者パスワード"

  tags = var.common_tags
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id     = aws_secretsmanager_secret.argocd_admin.id
  secret_string = random_password.argocd_admin.result
}

# ArgoCDのbcryptハッシュ化されたパスワードを生成する
resource "htpasswd_password" "argocd_admin" {
  password = random_password.argocd_admin.result
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = "argocd"
  version    = var.argocd_version

  create_namespace = true

  values = [
    yamlencode({
      global = {
        domain = "argocd.${var.project_name}.internal"
      }

      server = {
        # Serviceタイプは ClusterIP + Ingressを使用する理由：
        # LoadBalancer にすると毎回新しいNLBが作成されIP/ドメインが変わる。
        # Ingress(ALB)経由にすることで証明書管理・ドメイン設定を一元化できる。
        service = {
          type = "ClusterIP"
        }

        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"      = "internet-facing"
            "alb.ingress.kubernetes.io/target-type" = "ip"
            # HTTPSリダイレクトの設定
            "alb.ingress.kubernetes.io/listen-ports"            = "[{\"HTTPS\":443},{\"HTTP\":80}]"
            "alb.ingress.kubernetes.io/ssl-redirect"            = "443"
            "alb.ingress.kubernetes.io/backend-protocol"        = "HTTPS"
          }
          tls = true
        }
      }

      configs = {
        secret = {
          # bcryptハッシュ化されたadminパスワードを設定
          argocdServerAdminPassword = htpasswd_password.argocd_admin.bcrypt
        }

        params = {
          # ArgoCDサーバーでTLSを終端する（ALBがHTTPSをバックエンドに転送するため）
          "server.insecure" = false
        }

        # RBAC設定: プロジェクト単位でアクセス制御
        rbac = {
          "policy.default" = "role:readonly"
          "policy.csv" = <<-EOT
            # 管理者ロール: 全操作を許可
            p, role:admin, applications, *, */*, allow
            p, role:admin, clusters, get, *, allow
            p, role:admin, repositories, *, *, allow
            p, role:admin, projects, *, *, allow

            # 開発者ロール: アプリケーションのsync/updateのみ許可
            p, role:developer, applications, get, */*, allow
            p, role:developer, applications, sync, */*, allow
            p, role:developer, logs, get, */*, allow

            # グループとロールのマッピング
            g, admin-group, role:admin
            g, developer-group, role:developer
          EOT
        }
      }

      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = var.argocd_irsa_role_arn
        }
      }

      # HA構成を無効化してコストを抑える（学習用）
      # 本番環境では ha.enabled=true を推奨
      redis-ha = {
        enabled = false
      }

      controller = {
        replicas = 1
      }

      repoServer = {
        replicas = 1
      }

      applicationSet = {
        replicas = 1
      }
    })
  ]

  depends_on = [helm_release.aws_load_balancer_controller]
}

################################################################################
# データソース
################################################################################

data "aws_caller_identity" "current" {}
