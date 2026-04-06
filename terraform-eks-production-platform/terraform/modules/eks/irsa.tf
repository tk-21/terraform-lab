################################################################################
# EKSモジュール - IRSA (IAM Roles for Service Accounts)
#
# IRSAの実装パターン：
# 1. aws_iam_openid_connect_provider でEKSのOIDCエンドポイントを登録
#    （main.tfで定義済み）
# 2. 用途ごとにIAMロールを作成
# 3. Trust PolicyのConditionにKubernetes ServiceAccountを明示的に指定
#    - StringEquals: "oidc.eks.region.amazonaws.com/id/XXXX:sub"
#                 = "system:serviceaccounts:{namespace}:{serviceaccount-name}"
# 4. Kubernetes ServiceAccountのannotationsにIAMロールARNを設定
#    （HelmのvaluesまたはKubernetesマニフェストで設定）
#
# 用途ごとにIAMロールを分離する理由（最小権限の原則）：
# 全アプリが同じロールを使うと、1つの脆弱性で全権限が奪われるリスクがある。
# 用途別に分離することで影響範囲を限定できる。
################################################################################

locals {
  # OIDC Provider URL（プロトコル部分を除いた文字列）
  # Trust PolicyのConditionキーに使用する
  oidc_provider_url = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

################################################################################
# Karpenter用IRSAロール
#
# Karpenterはノードの起動・終了・スポット中断処理を担当する。
# EC2インスタンスの起動に必要な権限を付与するが、
# すべてのEC2操作を許可せず、必要なアクションに限定する。
################################################################################

resource "aws_iam_role" "karpenter" {
  name = "${var.project_name}-${var.environment}-irsa-karpenter"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # karpenter-system NamespaceのkarpenterサービスアカウントのみTrust
          "${local.oidc_provider_url}:sub" = "system:serviceaccounts:karpenter:karpenter"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "karpenter" {
  name = "${var.project_name}-${var.environment}-policy-karpenter"
  role = aws_iam_role.karpenter.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EC2インスタンスの起動・終了に必要な権限
        Sid    = "KarpenterEC2"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet",
          "ec2:CreateLaunchTemplate",
          "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
          "ec2:RunInstances",
          "ec2:TerminateInstances",
        ]
        # EC2の操作は Karpenter が管理するリソースに限定できないため
        # タグベースの条件でリソースを制限することを推奨（本番ではcondition追加）
        Resource = "*"
      },
      {
        # EKSクラスター情報の取得（ブートストラップ設定取得に必要）
        Sid      = "KarpenterEKS"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.this.arn
      },
      {
        # Karpenterノード用InstanceProfileの使用権限
        Sid    = "KarpenterIAM"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = aws_iam_role.karpenter_node.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ec2.amazonaws.com"
          }
        }
      },
      {
        # スポットインスタンス関連リンクドロールの作成
        Sid      = "KarpenterSpot"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/spot.amazonaws.com/AWSServiceRoleForEC2Spot"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = "spot.amazonaws.com"
          }
        }
      },
      {
        # SQSキュー（スポット中断通知処理）へのアクセス
        Sid    = "KarpenterSQS"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
        Resource = aws_sqs_queue.karpenter_interruption.arn
      },
      {
        # インスタンスプロファイルの操作（Karpenter v0.32+で必要）
        Sid    = "KarpenterInstanceProfile"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile",
          "iam:GetInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:TagInstanceProfile",
        ]
        Resource = "*"
      },
    ]
  })
}

################################################################################
# Karpenter スポットインスタンス中断処理用SQS + EventBridge
#
# スポットインスタンス中断通知をSQSで受け取り、Karpenterが
# 2分前に通知を受けてノードのドレイン（Pod退避）を実施する仕組み。
# これがないとスポット中断時にPodが強制終了されサービス断が発生する。
################################################################################

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.project_name}-${var.environment}-sqs-karpenter-interruption"
  message_retention_seconds = 300 # 中断通知は5分以内に処理されるため短く設定

  tags = var.common_tags
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# EventBridgeルール: スポットインスタンス中断警告
resource "aws_cloudwatch_event_rule" "karpenter_spot_interruption" {
  name        = "${var.project_name}-${var.environment}-karpenter-spot-interruption"
  description = "Karpenter スポットインスタンス2分前中断通知"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_spot_interruption" {
  rule      = aws_cloudwatch_event_rule.karpenter_spot_interruption.name
  target_id = "KarpenterSQS"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EventBridgeルール: インスタンス状態変化（rebalance推奨等）
resource "aws_cloudwatch_event_rule" "karpenter_rebalance" {
  name        = "${var.project_name}-${var.environment}-karpenter-rebalance"
  description = "Karpenter EC2インスタンスリバランス推奨通知"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_rebalance" {
  rule      = aws_cloudwatch_event_rule.karpenter_rebalance.name
  target_id = "KarpenterSQS"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EventBridgeルール: EC2インスタンス状態変化
resource "aws_cloudwatch_event_rule" "karpenter_instance_state" {
  name        = "${var.project_name}-${var.environment}-karpenter-instance-state"
  description = "Karpenter EC2インスタンス状態変化通知"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance State-change Notification"]
  })

  tags = var.common_tags
}

resource "aws_cloudwatch_event_target" "karpenter_instance_state" {
  rule      = aws_cloudwatch_event_rule.karpenter_instance_state.name
  target_id = "KarpenterSQS"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

################################################################################
# AWS Load Balancer Controller用IRSAロール
#
# LBCはALB/NLBを作成・管理する。
# ELBの操作権限とターゲットグループの管理権限が必要。
################################################################################

resource "aws_iam_role" "lbc" {
  name = "${var.project_name}-${var.environment}-irsa-lbc"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # kube-system NamespaceのLBC ServiceAccountのみTrust
          "${local.oidc_provider_url}:sub" = "system:serviceaccounts:kube-system:aws-load-balancer-controller"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

# AWS Load Balancer Controller 公式推奨のIAMポリシー
resource "aws_iam_role_policy" "lbc" {
  name = "${var.project_name}-${var.environment}-policy-lbc"
  role = aws_iam_role.lbc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "LBCCore"
        Effect = "Allow"
        Action = [
          # ALB/NLBの作成・更新・削除
          "elasticloadbalancing:AddListenerCertificates",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateRule",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:DeleteRule",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:ModifyListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:RemoveListenerCertificates",
          "elasticloadbalancing:RemoveTags",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:SetWebAcl",
        ]
        Resource = "*"
      },
      {
        Sid    = "LBCEC2"
        Effect = "Allow"
        Action = [
          # VPC・サブネット・セキュリティグループの参照（ALB配置先の決定に必要）
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteSecurityGroup",
          "ec2:DeleteTags",
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeCoipPools",
          "ec2:DescribeInstances",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeTags",
          "ec2:DescribeVpcs",
          "ec2:GetCoipPoolUsage",
          "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = "*"
      },
      {
        # ACM証明書の参照（ALBのHTTPS設定に必要）
        Sid      = "LBCCertificate"
        Effect   = "Allow"
        Action   = ["acm:DescribeCertificate", "acm:ListCertificates"]
        Resource = "*"
      },
      {
        # WAFv2の関連付け（ALBへのWAF適用に必要）
        Sid    = "LBCWAFv2"
        Effect = "Allow"
        Action = [
          "wafv2:AssociateWebACL",
          "wafv2:DisassociateWebACL",
          "wafv2:GetWebACL",
          "wafv2:GetWebACLForResource",
        ]
        Resource = "*"
      },
      {
        # IAM ServiceLinkedRole作成（ELB初回使用時に必要）
        Sid    = "LBCServiceLinkedRole"
        Effect = "Allow"
        Action = ["iam:CreateServiceLinkedRole"]
        Resource = "arn:aws:iam::*:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing"
        Condition = {
          StringLike = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        # Cognito（ALBの認証機能に必要）
        Sid    = "LBCCognito"
        Effect = "Allow"
        Action = ["cognito-idp:DescribeUserPoolClient"]
        Resource = "*"
      },
    ]
  })
}

################################################################################
# ArgoCD用IRSAロール
#
# ArgoCDがS3バケットからHelmチャートやマニフェストを取得するための権限。
# 特定のS3バケットプレフィックスのみアクセスを許可し最小権限を実現する。
################################################################################

resource "aws_iam_role" "argocd" {
  name = "${var.project_name}-${var.environment}-irsa-argocd"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # argocd NamespaceのArgoCD server ServiceAccountのみTrust
          "${local.oidc_provider_url}:sub" = "system:serviceaccounts:argocd:argocd-server"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "argocd" {
  name = "${var.project_name}-${var.environment}-policy-argocd"
  role = aws_iam_role.argocd.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ArgoCDS3ReadOnly"
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:ListBucket",
      ]
      # 特定のS3バケット・プレフィックスのみアクセス許可
      # ワイルドカード(*) は使用禁止（CLAUDE.md参照）
      Resource = [
        "arn:aws:s3:::${var.project_name}-${var.environment}-argocd-artifacts",
        "arn:aws:s3:::${var.project_name}-${var.environment}-argocd-artifacts/*",
      ]
    }]
  })
}

################################################################################
# サンプルアプリ用IRSAロール
#
# アプリケーションがSecrets Managerから特定パスの機密情報のみ取得できるよう制限。
# パスプレフィックスで制限することで、他アプリのSecretに触れないようにする。
################################################################################

resource "aws_iam_role" "app" {
  name = "${var.project_name}-${var.environment}-irsa-app"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # sample-app Namespaceの sample-app ServiceAccountのみTrust
          "${local.oidc_provider_url}:sub" = "system:serviceaccounts:sample-app:sample-app"
          "${local.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "app" {
  name = "${var.project_name}-${var.environment}-policy-app"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AppSecretsManagerRead"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        # アプリ用パスプレフィックス以下のSecretのみアクセス許可
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.project_name}/${var.environment}/app/*"
      },
      {
        # KMSキーを使って暗号化されたSecretの復号に必要
        Sid      = "AppKMSDecrypt"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = aws_kms_key.eks.arn
      },
    ]
  })
}
