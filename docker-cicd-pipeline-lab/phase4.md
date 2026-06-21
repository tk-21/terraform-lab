# ✅Phase 4 — 可観測性 (CloudWatch Dashboard + アラーム)

## このフェーズのゴール

本番品質のポートフォリオに必要な「見える化」レイヤーを追加する。
- CloudWatch Dashboard でパイプライン全体の健全性を一目で把握
- アラームで異常を即時検知 (ECS タスク障害 / デプロイ失敗)
- パイプライン実行履歴の可視化

---

## 作成するファイル

### `terraform/modules/observability/main.tf`

```hcl
# ─── CloudWatch Alarms ──────────────────────────────────────────

# ECS タスク数が 0 になったら即アラーム (サービス障害検知)
resource "aws_cloudwatch_metric_alarm" "ecs_running_tasks" {
  alarm_name          = "${var.name_prefix}-ecs-no-running-tasks"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  alarm_description   = "ECS サービスの実行中タスクが 0 になった — サービスダウンの可能性"
  treat_missing_data  = "breaching"  # データなし = タスクなしとして評価

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []
  ok_actions    = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = { Name = "${var.name_prefix}-alarm-ecs-tasks" }
}

# ALB 5xx エラー率アラーム (デプロイ失敗の早期検知)
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.name_prefix}-alb-high-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_ELB_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "ALB 5xx エラーが急増 — Blue/Green デプロイ失敗の可能性"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  alarm_actions = var.sns_topic_arn != "" ? [var.sns_topic_arn] : []

  tags = { Name = "${var.name_prefix}-alarm-alb-5xx" }
}

# CodePipeline 失敗アラーム
resource "aws_cloudwatch_event_rule" "pipeline_failure" {
  name        = "${var.name_prefix}-pipeline-failure"
  description = "CodePipeline のステージ失敗を検知"

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Stage Execution State Change"]
    detail = {
      state    = ["FAILED"]
      pipeline = [var.pipeline_name]
    }
  })
}

resource "aws_cloudwatch_event_target" "pipeline_failure_log" {
  rule      = aws_cloudwatch_event_rule.pipeline_failure.name
  target_id = "PipelineFailureLog"
  arn       = aws_cloudwatch_log_group.events.arn
}

resource "aws_cloudwatch_log_group" "events" {
  name              = "/aws/events/${var.name_prefix}/pipeline"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-pipeline-events" }
}

# ─── CloudWatch Dashboard ────────────────────────────────────────

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-overview"

  dashboard_body = jsonencode({
    widgets = [
      # タイトル
      {
        type   = "text"
        x = 0; y = 0; width = 24; height = 1
        properties = {
          markdown = "# ${var.name_prefix} — CI/CD パイプライン ダッシュボード"
        }
      },
      # ECS 実行中タスク数
      {
        type   = "metric"
        x = 0; y = 1; width = 8; height = 6
        properties = {
          title  = "ECS 実行中タスク数"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [[
            "ECS/ContainerInsights", "RunningTaskCount",
            "ClusterName", var.ecs_cluster_name,
            "ServiceName", var.ecs_service_name
          ]]
        }
      },
      # ALB レスポンスコード分布
      {
        type   = "metric"
        x = 8; y = 1; width = 8; height = 6
        properties = {
          title  = "ALB HTTPレスポンスコード"
          view   = "timeSeries"
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_2XX_Count", "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_4XX_Count",    "LoadBalancer", var.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count",    "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      # ALB レイテンシ
      {
        type   = "metric"
        x = 16; y = 1; width = 8; height = 6
        properties = {
          title  = "ALB レイテンシ (p99)"
          view   = "timeSeries"
          stat   = "p99"
          period = 60
          metrics = [[
            "AWS/ApplicationELB", "TargetResponseTime",
            "LoadBalancer", var.alb_arn_suffix
          ]]
        }
      },
      # CodeBuild ビルド時間
      {
        type   = "metric"
        x = 0; y = 7; width = 12; height = 6
        properties = {
          title  = "CodeBuild ビルド時間 (秒)"
          view   = "timeSeries"
          stat   = "Average"
          period = 300
          metrics = [[
            "AWS/CodeBuild", "Duration",
            "ProjectName", var.codebuild_project_name,
            "BuildStatus", "SUCCEEDED"
          ]]
        }
      },
      # ECS CPU / メモリ使用率
      {
        type   = "metric"
        x = 12; y = 7; width = 12; height = 6
        properties = {
          title  = "ECS CPU / メモリ使用率 (%)"
          view   = "timeSeries"
          stat   = "Average"
          period = 60
          metrics = [
            ["ECS/ContainerInsights", "CpuUtilized",    "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name],
            ["ECS/ContainerInsights", "MemoryUtilized", "ClusterName", var.ecs_cluster_name, "ServiceName", var.ecs_service_name]
          ]
        }
      }
    ]
  })
}
```

### `terraform/modules/observability/variables.tf`

```hcl
variable "name_prefix"            { type = string }
variable "ecs_cluster_name"       { type = string }
variable "ecs_service_name"       { type = string }
variable "alb_arn_suffix"         { type = string }
variable "codebuild_project_name" { type = string }
variable "pipeline_name"          { type = string }
variable "sns_topic_arn" {
  type    = string
  default = ""  # 未設定の場合はアラームアクションなし
}
```

### `terraform/modules/observability/outputs.tf`

```hcl
output "dashboard_url" {
  value = "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${var.name_prefix}-overview"
}
```

---

## `terraform/main.tf` に追記

```hcl
module "observability" {
  source = "./modules/observability"

  name_prefix            = local.name_prefix
  ecs_cluster_name       = module.ecs.cluster_name
  ecs_service_name       = module.ecs.service_name
  alb_arn_suffix         = module.alb.alb_arn_suffix  # outputs.tf に追記が必要
  codebuild_project_name = module.codebuild.project_name
  pipeline_name          = module.codepipeline.pipeline_name
}
```

## `terraform/modules/alb/outputs.tf` に追記

```hcl
output "alb_arn_suffix" {
  # CloudWatch メトリクスのディメンジョンに必要なサフィックス形式
  value = aws_lb.main.arn_suffix
}
```

---

## 実行手順

```bash
# terraform apply
terraform -chdir=terraform fmt -recursive
terraform -chdir=terraform apply -auto-approve

# ダッシュボード URL 確認
terraform -chdir=terraform output -raw observability_dashboard_url 2>/dev/null || \
  echo "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards"

# アラーム状態確認
aws cloudwatch describe-alarms \
  --alarm-names "cicd-lab-prod-ecs-no-running-tasks" "cicd-lab-prod-alb-high-5xx" \
  --query 'MetricAlarms[*].{Name:AlarmName,State:StateValue}'

# 負荷テスト (ALB メトリクスを生成)
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
for i in $(seq 1 50); do
  curl -s http://$ALB_DNS/ > /dev/null
  sleep 0.5
done
echo "50 リクエスト完了 — ダッシュボードで確認"
```

---

## 完了チェックリスト

- [ ] CloudWatch Dashboard `cicd-lab-prod-overview` が作成されている
- [ ] ダッシュボードに 5 つのウィジェットが表示されている
- [ ] ECS タスク数アラームが `OK` 状態である
- [ ] ALB 5xx アラームが `OK` 状態である
- [ ] 負荷テスト後にダッシュボードでメトリクスが更新されている
- [ ] EventBridge ルールが CodePipeline 失敗を検知できる状態である

## 口頭説明チェックポイント

> 以下を見ずに 3 分間で説明できるか確認すること

1. **treat_missing_data = "breaching" にした理由は？** — ECS タスク数監視の文脈で説明できるか？
2. **ALB の arn_suffix を使う理由は？** — CloudWatch のディメンジョン仕様との関係は？
3. **Container Insights を有効化しないと取れないメトリクスは何か？**
4. **EventBridge で CodePipeline 失敗を検知する利点は？** — CloudWatch Alarm だけでは不十分な理由は？