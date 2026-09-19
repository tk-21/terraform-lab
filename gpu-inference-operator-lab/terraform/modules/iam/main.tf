data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  name_prefix = "${var.prefix}-${var.env}"
  # OIDCのhttps://プレフィックスを除去してConditionキーを生成する
  oidc_subject = trimprefix(var.oidc_provider_url, "https://")

  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })
}

# Operator本体のIRSAロール
# Bedrockフォールバック・CloudWatch・SSM・EC2(Podスケジューリング状態確認)のみに限定する
resource "aws_iam_role" "operator" {
  # 64文字制限: "giop-dev-operator-irsa-role" = 27文字 (余裕あり)
  name = "${local.name_prefix}-operator-irsa-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = var.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          # ServiceAccountのsub: Operatorのnamespace/serviceaccountに限定する
          "${local.oidc_subject}:sub" = "system:serviceaccount:${var.operator_namespace}:${var.operator_service_account}"
          "${local.oidc_subject}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy" "operator" {
  name = "${local.name_prefix}-operator-policy"
  role = aws_iam_role.operator.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # BedrockモデルへのInvokeのみ許可する
        # フォールバック時にvLLMの代わりにBedrockで推論するために必要
        # ワイルドカードは使わず、変数で指定したモデルIDのみに絞る
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
        ]
        Resource = [
          for model_id in var.bedrock_model_ids :
          "arn:aws:bedrock:${data.aws_region.current.name}::foundation-model/${model_id}"
        ]
      },
      {
        # CloudWatch Metricsへのカスタムメトリクス書き込み
        # Operatorの反応速度計測(スケーリングレイテンシ)を記録するために必要
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData",
        ]
        # cloudwatch:PutMetricData はIAMリソースレベル権限が非対応のためAWS側の制約で * が必須
        # Namespace条件で自プロジェクト専用Namespaceに書き込みを限定してリスクを最小化する
        Resource = "*"
        Condition = {
          StringEquals = {
            # 自分のNamespaceのメトリクスのみ書き込み可能にする
            "cloudwatch:namespace" = "GPUInferenceOperator"
          }
        }
      },
      {
        # SSM Parameter StoreからChatwork APIトークンを取得する
        # シークレットの直接ハードコード禁止ポリシーへの対応
        Sid    = "SSMGetParameter"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
        ]
        Resource = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/gpu-inference-operator-lab/*"
      },
    ]
  })
}
