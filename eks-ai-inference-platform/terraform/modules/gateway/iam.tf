# ────────────────────────────────────────────────
# AI Gateway Pod IRSA
# ai-inference namespace の ai-gateway-sa のみが引き受けられる (最小権限)
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "gateway_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    # ai-inference namespace の ai-gateway-sa にのみ権限を付与する
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:ai-inference:ai-gateway-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway_sa" {
  # 64文字制限: "eks-ai-inf-dev-ai-gateway-sa" = 28文字
  name               = "${local.name_prefix}-ai-gateway-sa"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "gateway_permissions" {
  # Bedrock 呼び出し: フォールバック先の Claude Haiku モデルのみに限定する
  statement {
    sid     = "BedrockInvokeHaiku"
    effect  = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-haiku-4-5-20251001",
    ]
  }

  # SSM 読み取り: 予算上限パラメータのみに限定する
  # ワイルドカードを避けて /ai-inference/ 配下のパラメータのみに絞る
  statement {
    sid    = "SSMReadBudget"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:*:parameter/ai-inference/*",
    ]
  }
}

resource "aws_iam_role_policy" "gateway_permissions" {
  name   = "${local.name_prefix}-ai-gateway-policy"
  role   = aws_iam_role.gateway_sa.id
  policy = data.aws_iam_policy_document.gateway_permissions.json
}

# ────────────────────────────────────────────────
# コストアラート Lambda 実行ロール
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cost_alert_lambda" {
  # 64文字制限: "eks-ai-inf-dev-cost-alert-lambda" = 32文字
  name               = "${local.name_prefix}-cost-alert-lambda"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

# CloudWatch Logs への書き込み: Lambda 実行ログの出力に必要
resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.cost_alert_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {
  # Chatwork Token の取得: SecureString を復号する権限が必要
  statement {
    sid    = "SSMReadChatwork"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = [
      "arn:aws:ssm:ap-northeast-1:*:parameter/chatwork/*",
    ]
  }

  # KMS: SSM SecureString の復号に使用 (カスタムキーを使う場合に必要)
  statement {
    sid     = "KMSDecryptSSM"
    effect  = "Allow"
    actions = ["kms:Decrypt"]
    # SSM が管理する AWS マネージドキーのみに限定する
    resources = ["arn:aws:kms:ap-northeast-1:*:key/alias/aws/ssm"]
  }

  # DLQ (SQS) への書き込み: 処理失敗時にメッセージを保存する
  statement {
    sid       = "SQSSendDLQ"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq.arn]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "${local.name_prefix}-cost-alert-lambda-policy"
  role   = aws_iam_role.cost_alert_lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}
