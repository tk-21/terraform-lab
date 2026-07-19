# ────────────────────────────────────────────────
# Amazon Managed Prometheus (AMP) ワークスペース
# ────────────────────────────────────────────────

resource "aws_prometheus_workspace" "main" {
  # AMPはサーバーレスのためPrometheus本体の運用コスト(冗長化/バックアップ/アップグレード)が不要
  alias = "${local.name_prefix}-ai-inference"

  tags = local.common_tags
}

# ────────────────────────────────────────────────
# OTEL Collector → AMP への書き込み用 IRSA
# ────────────────────────────────────────────────

data "aws_iam_policy_document" "otel_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    # monitoring namespace の otel-collector-sa にのみ権限を付与する (最小権限)
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:monitoring:otel-collector-sa"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "otel_collector" {
  # 64文字制限: "eks-ai-inf-dev-otel-collector" = 29文字
  name               = "${local.name_prefix}-otel-collector"
  assume_role_policy = data.aws_iam_policy_document.otel_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "amp_write" {
  statement {
    effect = "Allow"
    actions = [
      # remote_writeに必要な最小権限: 書き込み専用とし読み取りは許可しない
      "aps:RemoteWrite",
      # OTEL CollectorのヘルスチェックがメトリクスIDを照合するために使用
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
    ]
    # このワークスペースにのみ書き込みを限定し、他のAMPワークスペースへの誤送信を防ぐ
    resources = [aws_prometheus_workspace.main.arn]
  }
}

resource "aws_iam_role_policy" "otel_amp_write" {
  name   = "${local.name_prefix}-otel-amp-write"
  role   = aws_iam_role.otel_collector.id
  policy = data.aws_iam_policy_document.amp_write.json
}

# ────────────────────────────────────────────────
# Amazon Managed Grafana (AMG) ワークスペース
# ────────────────────────────────────────────────

resource "aws_iam_role" "grafana" {
  # 64文字制限: "eks-ai-inf-dev-amg-role" = 23文字
  name = "${local.name_prefix}-amg-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

# AMP クエリ権限: Grafanaがダッシュボード表示でAMPにPromeQLを発行するために必要
resource "aws_iam_role_policy_attachment" "grafana_amp_query" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusQueryAccess"
}

# CloudWatch権限: コスト情報をGrafanaで参照するために追加
resource "aws_iam_role_policy_attachment" "grafana_cloudwatch" {
  role       = aws_iam_role.grafana.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_grafana_workspace" "main" {
  name                     = "${local.name_prefix}-ai-inference"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"

  # AMPとCloudWatchを統一ダッシュボードで参照できるようにする
  data_sources = ["PROMETHEUS", "CLOUDWATCH"]

  # Grafanaがデータソースにアクセスする際に引き受けるIAMロール
  role_arn = aws_iam_role.grafana.arn

  tags = local.common_tags
}
