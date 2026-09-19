locals {
  name_prefix = "${var.prefix}-${var.env}"

  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })

  # VPC Endpointが必要なサービスの定義
  # NAT Gatewayを使わないため、EKSノードからAWSサービスへのアクセスはすべてVPC経由にする
  interface_endpoints = {
    ecr_api = {
      service_name = "com.amazonaws.ap-northeast-1.ecr.api"
      # EKSノードがECRのAPIを呼び出してイメージメタデータを取得するために必要
    }
    ecr_dkr = {
      service_name = "com.amazonaws.ap-northeast-1.ecr.dkr"
      # EKSノードがECRからコンテナイメージをpullするために必要
    }
    sts = {
      service_name = "com.amazonaws.ap-northeast-1.sts"
      # IRSAでKubernetesのServiceAccountがSTS AssumeRoleWithWebIdentityを呼び出すために必要
    }
    logs = {
      service_name = "com.amazonaws.ap-northeast-1.logs"
      # CloudWatch Logsへのログ送信のために必要
    }
    ssm = {
      service_name = "com.amazonaws.ap-northeast-1.ssm"
      # Chatwork APIトークン等のシークレットをSSM Parameter Storeから取得するために必要
    }
    bedrock_runtime = {
      service_name = "com.amazonaws.ap-northeast-1.bedrock-runtime"
      # Bedrockフォールバック時にベクトル推論リクエストを送信するために必要
    }
  }
}
