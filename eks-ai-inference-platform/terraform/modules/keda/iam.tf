# ────────────────────────────────────────────────
# KEDA → AMP クエリ用 IRSA
# keda namespace の keda-operator ServiceAccount のみが引き受けられる
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "keda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    # keda namespace の keda-operator にのみ権限を付与する (最小権限)
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:keda:keda-operator"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda_amp_irsa" {
  # 64文字制限: "eks-ai-inf-dev-keda-amp-irsa" = 28文字
  name               = "${local.name_prefix}-keda-amp-irsa"
  assume_role_policy = data.aws_iam_policy_document.keda_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "keda_amp_query" {
  statement {
    sid    = "AMPQueryForKEDA"
    effect = "Allow"
    actions = [
      # ScaledObjectのPrometheusトリガーがvllm_num_requests_waitingをクエリするために必要
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
    ]
    # このAMPワークスペースへのクエリのみに限定する
    resources = [var.amp_workspace_arn]
  }
}

resource "aws_iam_role_policy" "keda_amp_query" {
  name   = "${local.name_prefix}-keda-amp-query"
  role   = aws_iam_role.keda_amp_irsa.id
  policy = data.aws_iam_policy_document.keda_amp_query.json
}

# ────────────────────────────────────────────────
# スケール通知 Lambda 実行ロール
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "scale_notify_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "scale_notify_lambda" {
  # 64文字制限: "eks-ai-inf-dev-scale-notify-lambda" = 34文字
  name               = "${local.name_prefix}-scale-notify-lambda"
  assume_role_policy = data.aws_iam_policy_document.scale_notify_assume_role.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "scale_notify_basic" {
  role       = aws_iam_role.scale_notify_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "scale_notify_permissions" {
  # Chatwork Token取得: SecureStringを復号する権限が必要
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

  # EC2 state-change イベントにはinstance-typeが含まれないため動的取得する
  # GPUノード (g4dn/g5) かどうかを判定するためのみ使用する (最小権限)
  statement {
    sid     = "EC2DescribeForInstanceType"
    effect  = "Allow"
    actions = ["ec2:DescribeInstances"]
    # DescribeInstancesはリソースレベルのARN制限が不可のため * を使用する
    # (AWSのAPIの制約: https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonec2.html)
    resources = ["*"]
  }

  # KMS: SSM SecureStringの復号に使用する
  statement {
    sid       = "KMSDecryptSSM"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["arn:aws:kms:ap-northeast-1:*:key/alias/aws/ssm"]
  }

  # DLQへの書き込み: Lambda処理失敗時にメッセージを保存する
  statement {
    sid       = "SQSSendDLQ"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.scale_notify_dlq.arn]
  }
}

resource "aws_iam_role_policy" "scale_notify_permissions" {
  name   = "${local.name_prefix}-scale-notify-policy"
  role   = aws_iam_role.scale_notify_lambda.id
  policy = data.aws_iam_policy_document.scale_notify_permissions.json
}
