# =============================================================
# 観測基盤モジュール
# Amazon Managed Prometheus（AMP）+ Amazon Managed Grafana（AMG）
# + CloudWatch Container Insights
#
# 設計:
# - AMP: Prometheusメトリクスの長期保存（90日）
# - AMG: Grafanaダッシュボード（マネージドで運用負荷ゼロ）
# - ADOT: EKS上のOpenTelemetryコレクター（AMP送信役）
# - IRSA必須: Pod単位のIAMロールでノードに権限を与えない
# =============================================================

terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

# --- Amazon Managed Prometheus ワークスペース ---
resource "aws_prometheus_workspace" "main" {
  alias = "${var.cluster_name}-prometheus"

  logging_configuration {
    log_group_arn = "${aws_cloudwatch_log_group.amp.arn}:*"
  }

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "amp" {
  name              = "/aws/prometheus/${var.cluster_name}"
  retention_in_days = 30
  tags              = var.common_tags
}

# --- Amazon Managed Grafana ワークスペース ---
resource "aws_grafana_workspace" "main" {
  name                     = "${var.cluster_name}-grafana"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["AWS_SSO"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn

  data_sources = ["PROMETHEUS", "CLOUDWATCH", "XRAY"]

  tags = var.common_tags
}

# --- Grafana IAMロール ---
# ロール名: {cluster_name}-grafana-role（最大64文字）
resource "aws_iam_role" "grafana" {
  name = "${var.cluster_name}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "grafana.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "grafana" {
  name = "${var.cluster_name}-grafana-policy"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # AMPクエリ: このワークスペースのみに限定
      {
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace"
        ]
        Resource = aws_prometheus_workspace.main.arn
      },
      # CloudWatch読み取り（Container Insights可視化用）
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:GetQueryResults"
        ]
        Resource = "*"
      },
      # X-Ray読み取り（トレース可視化用）
      {
        Effect = "Allow"
        Action = [
          "xray:GetTraceSummaries",
          "xray:GetGroups",
          "xray:GetGroup",
          "xray:GetTimeSeriesServiceStatistics"
        ]
        Resource = "*"
      }
    ]
  })
}

# --- ADOT（AWS Distro for OpenTelemetry）IRSA ---
# EKSクラスター上のADOTコレクターがAMPにメトリクスを送信するためのIAMロール
# Namespace: amazon-metrics / ServiceAccount: adot-collector
resource "aws_iam_role" "adot" {
  name = "${var.cluster_name}-adot-collector"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${var.oidc_issuer}:sub" = "system:serviceaccount:amazon-metrics:adot-collector"
          "${var.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

# AWSマネージドポリシー: Prometheusリモートライト権限
resource "aws_iam_role_policy_attachment" "adot_amp" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonPrometheusRemoteWriteAccess"
  role       = aws_iam_role.adot.name
}

# --- Container Insights ロググループ ---
resource "aws_cloudwatch_log_group" "container_insights" {
  name              = "/aws/containerinsights/${var.cluster_name}/performance"
  retention_in_days = 30
  tags              = var.common_tags
}
