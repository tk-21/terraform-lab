################################################################################
# Observabilityモジュール
#
# 3層の可観測性スタック：
# 1. CloudWatch Container Insights: ノード・Pod・コンテナレベルのメトリクス・ログ
# 2. Amazon Managed Prometheus (AMP): Prometheusメトリクスの長期保存
# 3. Amazon Managed Grafana (AMG): 統合ダッシュボード
################################################################################

################################################################################
# CloudWatch Container Insights
#
# Container InsightsをEKSマネージドアドオンで有効化する理由：
# 手動でDaemonSetをデプロイするより、マネージドアドオンの方が
# EKSバージョンアップ時の互換性が自動保証される。
################################################################################

# Container Insights用IAMロール
resource "aws_iam_role" "container_insights" {
  name = "${var.project_name}-${var.environment}-irsa-container-insights"

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
          # amazon-cloudwatch NamespaceのServiceAccountのみTrust
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:amazon-cloudwatch:cloudwatch-agent"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

# CloudWatchAgentServerPolicy: メトリクス・ログをCloudWatchに送信するための権限
resource "aws_iam_role_policy_attachment" "container_insights" {
  role       = aws_iam_role.container_insights.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# EKSマネージドアドオンとしてContainer Insightsを有効化
# マネージドアドオンを使う理由：
# - Fluentd等の手動デプロイより運用負荷が低い
# - EKSバージョンとの互換性が保証される
resource "aws_eks_addon" "amazon_cloudwatch_observability" {
  cluster_name             = var.cluster_name
  addon_name               = "amazon-cloudwatch-observability"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # IRSAロールを関連付ける
  service_account_role_arn = aws_iam_role.container_insights.arn

  tags = var.common_tags
}

################################################################################
# Amazon Managed Prometheus (AMP)
#
# PrometheusメトリクスをAWSマネージドで保存する。
# セルフホストPrometheusと比較した利点：
# - ストレージ管理不要
# - 高可用性が自動保証
# - IAMベースのアクセス制御
################################################################################

resource "aws_prometheus_workspace" "this" {
  alias = "${var.project_name}-${var.environment}-amp"

  tags = var.common_tags
}

# Prometheus Remote Write用IRSAロール
# EKS上のPrometheusがAMPにRemote Writeするための権限
resource "aws_iam_role" "prometheus_remote_write" {
  name = "${var.project_name}-${var.environment}-irsa-prom-rw"

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
          # monitoring NamespaceのPrometheus ServiceAccountのみTrust
          "${var.oidc_provider_url}:sub" = "system:serviceaccount:monitoring:prometheus-server"
          "${var.oidc_provider_url}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "prometheus_remote_write" {
  name = "${var.project_name}-${var.environment}-policy-prom-rw"
  role = aws_iam_role.prometheus_remote_write.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AMPRemoteWrite"
      Effect = "Allow"
      Action = [
        # AMPへのメトリクス書き込み権限
        "aps:RemoteWrite",
        "aps:GetSeries",
        "aps:GetLabels",
        "aps:GetMetricMetadata",
      ]
      # 特定のAMPワークスペースのみに制限
      Resource = aws_prometheus_workspace.this.arn
    }]
  })
}

# Prometheusをself-managed Helmチャートでデプロイ
# AMPはストレージのみ提供するため、スクレイピングはEKS上のPrometheusが担当する
resource "helm_release" "prometheus" {
  name       = "prometheus"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus"
  namespace  = "monitoring"
  version    = "~> 25.0"

  create_namespace = true

  values = [
    yamlencode({
      serviceAccounts = {
        server = {
          annotations = {
            # IRSAロールをServiceAccountに設定
            "eks.amazonaws.com/role-arn" = aws_iam_role.prometheus_remote_write.arn
          }
        }
      }

      server = {
        # AMPへのRemote Write設定
        # sigv4はAWS SigV4署名によるAMPへの認証
        remoteWrite = [{
          url = "${aws_prometheus_workspace.this.prometheus_endpoint}api/v1/remote_write"
          sigv4 = {
            region = var.aws_region
          }
          queue_config = {
            max_samples_per_send = 1000
            max_shards           = 200
            capacity             = 2500
          }
        }]

        # 長期保存はAMPに任せるためローカル保存は短期間に設定してコスト削減
        retention = "2h"

        # AMPへRemote Writeするため、ローカルTSDBの永続ボリュームは不要。
        # EBS CSI DriverおよびStorageClassが未構成でもPodをスケジュールできるようにする。
        persistentVolume = {
          enabled = false
        }

        resources = {
          requests = {
            cpu    = "500m"
            memory = "512Mi"
          }
          limits = {
            cpu    = "1000m"
            memory = "1Gi"
          }
        }
      }

      # Alertmanagerは不要（AMGのアラート機能を使用）
      alertmanager = {
        enabled = false
      }

      # Push Gatewayは使用しない（pull型スクレイピングで統一）
      pushgateway = {
        enabled = false
      }
    })
  ]
}

################################################################################
# Amazon Managed Grafana (AMG)
#
# CloudWatchとAMPの両方をデータソースとして統合ダッシュボードを提供。
# セルフホストGrafanaと比較した利点：
# - 認証管理不要（AWS SSO統合）
# - Grafanaサーバーの運用不要
################################################################################

# AMGワークスペース用IAMロール
resource "aws_iam_role" "grafana" {
  name = "${var.project_name}-${var.environment}-role-grafana"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "grafana.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "grafana" {
  name = "${var.project_name}-${var.environment}-policy-grafana"
  role = aws_iam_role.grafana.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # CloudWatchメトリクス・ログの読み取り
        Sid    = "GrafanaCloudWatch"
        Effect = "Allow"
        Action = [
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricData",
          "cloudwatch:GetInsightRuleReport",
          "logs:DescribeLogGroups",
          "logs:GetLogGroupFields",
          "logs:StartQuery",
          "logs:StopQuery",
          "logs:GetQueryResults",
          "logs:GetLogEvents",
        ]
        Resource = "*"
      },
      {
        # AMPワークスペースからのメトリクス読み取り
        Sid    = "GrafanaAMP"
        Effect = "Allow"
        Action = [
          "aps:QueryMetrics",
          "aps:GetSeries",
          "aps:GetLabels",
          "aps:GetMetricMetadata",
          "aps:ListWorkspaces",
          "aps:DescribeWorkspace",
        ]
        Resource = aws_prometheus_workspace.this.arn
      },
    ]
  })
}

resource "aws_grafana_workspace" "this" {
  name        = "${var.project_name}-${var.environment}-grafana"
  description = "EKS本番プラットフォーム統合監視ダッシュボード"

  # Grafana自体が使用するIAMロール
  role_arn = aws_iam_role.grafana.arn

  account_access_type = "CURRENT_ACCOUNT"

  # AWS SSOを認証プロバイダーとして使用する理由：
  # IAMユーザーのパスワード管理が不要になる。
  # 組織のSSO設定を流用してGrafanaへのアクセス権を一元管理できる。
  authentication_providers = ["AWS_SSO"]

  # Grafanaの権限をAWS側で管理する
  permission_type = "SERVICE_MANAGED"

  # データソースを明示的に有効化する理由：
  # GrafanaワークスペースがそれぞれのサービスAPIを呼び出す権限の根拠になる
  data_sources = [
    "PROMETHEUS",    # AMP経由でPrometheusメトリクスを参照
    "CLOUDWATCH",   # CloudWatch メトリクス・ログを参照
  ]

  tags = var.common_tags
}

# Grafana管理者ユーザーをSSOで招待
resource "aws_grafana_role_association" "admin" {
  count = length(var.grafana_admin_user_ids) > 0 ? 1 : 0

  role         = "ADMIN"
  user_ids     = var.grafana_admin_user_ids
  workspace_id = aws_grafana_workspace.this.id
}
