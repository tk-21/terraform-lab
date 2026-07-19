# =============================================================================
# CloudWatch Dashboard — ECS vs EKS 比較ビュー
# =============================================================================
# ECS と EKS を横並びで計測できるダッシュボード。
# ロードテスト中にスケーリング挙動・レイテンシ・SQS 深度をリアルタイム確認する。

resource "aws_cloudwatch_dashboard" "comparison" {
  dashboard_name = "deepdive-ecs-eks-comparison"

  dashboard_body = jsonencode({
    widgets = [

      # ── 行1左: SQS キュー深度（共通インフラ） ───────────────────────────────
      # ロードテスト中にキューが積まれ、Worker が消費していく様子を可視化
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "SQS — キュー深度（ロードテスト確認用）"
          region = "ap-northeast-1"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "deepdive-job-queue",
            { stat = "Maximum", period = 60, label = "Visible Messages" }],
            ["AWS/SQS", "NumberOfMessagesSent",
              "QueueName", "deepdive-job-queue",
            { stat = "Sum", period = 60, label = "Sent" }],
            ["AWS/SQS", "NumberOfMessagesDeleted",
              "QueueName", "deepdive-job-queue",
            { stat = "Sum", period = 60, label = "Processed" }],
          ]
          view   = "timeSeries"
          period = 60
        }
      },

      # ── 行1右: Worker 数比較（ECS vs EKS） ──────────────────────────────────
      # スケールアウト速度の差を視覚的に確認するためのコアウィジェット
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Worker 数比較: ECS (Fargate) vs EKS (Karpenter+KEDA)"
          region = "ap-northeast-1"
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount",
              "ClusterName", "deepdive-ecs",
              "ServiceName", "deepdive-job-worker",
            { stat = "Maximum", period = 60, label = "ECS Worker Tasks" }],
            ["ContainerInsights", "pod_number_of_running_containers",
              "ClusterName", "deepdive-eks",
              "Namespace", "deepdive",
              "PodName", "deepdive-worker",
            { stat = "Maximum", period = 60, label = "EKS Worker Pods" }],
          ]
          view = "timeSeries"
        }
      },

      # ── 行2左: ECS CPU 使用率 ───────────────────────────────────────────────
      # CloudWatch Alarm の評価トリガーと Step Scaling の発火タイミングを確認
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ECS — CPU 使用率（API + Worker）"
          region = "ap-northeast-1"
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized",
              "ClusterName", "deepdive-ecs",
              "ServiceName", "deepdive-api",
            { stat = "Average", period = 60, label = "API CPU (avg)" }],
            ["ECS/ContainerInsights", "CpuUtilized",
              "ClusterName", "deepdive-ecs",
              "ServiceName", "deepdive-job-worker",
            { stat = "Average", period = 60, label = "Worker CPU (avg)" }],
          ]
          view = "timeSeries"
        }
      },

      # ── 行2右: EKS Pod CPU + ノード数 ───────────────────────────────────────
      # Karpenter がノードを追加するタイミングを Worker Pod 増加と照合できる
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "EKS — Pod CPU + Karpenter ノード数"
          region = "ap-northeast-1"
          metrics = [
            ["ContainerInsights", "pod_cpu_utilization",
              "ClusterName", "deepdive-eks",
              "Namespace", "deepdive",
            { stat = "Average", period = 60, label = "Pod CPU (avg)" }],
            ["ContainerInsights", "node_number_of_running_pods",
              "ClusterName", "deepdive-eks",
            { stat = "Maximum", period = 60, label = "Node Running Pods" }],
          ]
          view = "timeSeries"
        }
      },

      # ── 行3: ALB レスポンスタイム比較（全幅） ───────────────────────────────
      # p50/p95/p99 を ECS vs EKS で横並び比較
      # NOTE: LoadBalancer の値は terraform apply 後に実際の ARN suffix に置き換える
      #       aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn'
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 24
        height = 6
        properties = {
          title  = "ALB レスポンスタイム比較 (p50 / p95 / p99)"
          region = "ap-northeast-1"
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_AFTER_APPLY",
            { stat = "p50", period = 60, label = "ECS p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_AFTER_APPLY",
            { stat = "p95", period = 60, label = "ECS p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-ecs-alb/REPLACE_AFTER_APPLY",
            { stat = "p99", period = 60, label = "ECS p99" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-eks-alb/REPLACE_AFTER_APPLY",
            { stat = "p50", period = 60, label = "EKS p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-eks-alb/REPLACE_AFTER_APPLY",
            { stat = "p95", period = 60, label = "EKS p95" }],
            ["AWS/ApplicationELB", "TargetResponseTime",
              "LoadBalancer", "app/deepdive-eks-alb/REPLACE_AFTER_APPLY",
            { stat = "p99", period = 60, label = "EKS p99" }],
          ]
          view = "timeSeries"
        }
      },

    ]
  })
}

output "dashboard_url" {
  description = "ECS vs EKS 比較ダッシュボード URL"
  value       = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${aws_cloudwatch_dashboard.comparison.dashboard_name}"
}
