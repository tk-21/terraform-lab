# --- EKS クラスター IAM Role ---
resource "aws_iam_role" "eks_cluster" {
  # IAMロール名は64文字以内のAWSハード制限に注意
  name = "deepdive-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- EKS クラスター用 Security Group ---
resource "aws_security_group" "eks_cluster" {
  name   = "deepdive-eks-cluster-sg"
  vpc_id = local.vpc_id
  # EKS がノードと通信するための最小限の設定（EKS マネージドルールが追加される）

  tags = { Name = "deepdive-eks-cluster-sg" }
}

# --- EKS クラスター本体 ---
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = "1.30"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids = concat(local.private_subnet_ids, local.public_subnet_ids)
    # プライベートエンドポイント: Karpenter ノードが VPC 内から API サーバーへアクセス
    endpoint_private_access = true
    # パブリックエンドポイント: ローカルから kubectl を実行するため
    endpoint_public_access = true
    security_group_ids     = [aws_security_group.eks_cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  access_config {
    # API モード: aws-auth ConfigMap を廃止し EKS Access Entries を使用
    # これにより Terraform で RBAC を管理できる
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# --- System ノードグループ ---
# CoreDNS, Karpenter controller など System Pod 専用ノード
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = local.eks_node_role_arn
  subnet_ids      = local.private_subnet_ids
  ami_type        = "AL2_ARM_64" # Graviton2: arm64 統一方針
  instance_types  = ["t4g.medium"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 4
  }

  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
    # このノードはシステム Pod 専用。アプリ Pod はここにスケジュールされない
    # Karpenter がワークロード Pod 用に別ノードをプロビジョニングする
  }

  labels = { "role" = "system" }
}

# --- EKS マネージドアドオン ---
resource "aws_eks_addon" "addons" {
  for_each = {
    # Pod ネットワーク: Prefix Delegation で Pod 数上限を大幅増加
    "vpc-cni" = {
      addon_name = "vpc-cni"
      configuration_values = jsonencode({
        env = {
          # Prefix Delegation: /28 プレフィックスを割り当てることで
          # 1 ノードあたりの Pod 数上限を大幅増加
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    # DNS 解決: EKS 内部サービス間通信の基盤
    "coredns" = {
      addon_name           = "coredns"
      configuration_values = null
    }
    # ネットワークルール: Service の ClusterIP へのルーティング
    "kube-proxy" = {
      addon_name           = "kube-proxy"
      configuration_values = null
    }
    # Pod Identity Agent: IAM 認証の新方式 (2023 年〜)
    # OIDC IRSA と異なり、OIDC Provider の設定が不要になる
    "eks-pod-identity-agent" = {
      addon_name           = "eks-pod-identity-agent"
      configuration_values = null
    }
  }

  cluster_name         = aws_eks_cluster.main.name
  addon_name           = each.value.addon_name
  configuration_values = each.value.configuration_values

  # アドオンはノードグループが起動してから適用する
  depends_on = [aws_eks_node_group.system]
}

# --- Outputs ---
output "cluster_name" {
  value = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}

output "cluster_ca" {
  value = aws_eks_cluster.main.certificate_authority[0].data
}

output "cluster_arn" {
  value = aws_eks_cluster.main.arn
}
