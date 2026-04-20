# =============================================================================
# FISモジュール - カオスエンジニアリング実験テンプレート
# AWS Fault Injection Serviceで4種類の障害実験を定義する。
# 全実験はChaosTarget=trueタグを持つリソースのみ対象とし、
# 本番ワークロードへの誤適用を防止する。
# =============================================================================

# ------------------------------------------------------------
# StopCondition用 CloudWatchアラーム
# ノードCPU使用率が90%を超えると実験を自動停止し、クラスター過負荷を防ぐ。
# Container InsightsのNode CPUメトリクスを監視対象とする。
# ------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "fis_stop_condition" {
  alarm_name          = "${var.project}-fis-stop-condition-${var.environment}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 60
  statistic           = "Average"
  threshold           = 90
  alarm_description   = "FIS実験StopCondition: ノードCPU90%超で自動停止"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.cluster_name
  }

  tags = var.tags
}

# ------------------------------------------------------------
# FIS実験実行IAMロール
# FISサービスがEKS・EC2操作とCloudWatchアラーム評価を行うための権限を付与する。
# EC2のTerminateInstancesはChaosTarget=trueタグ付きリソースのみに制限し、
# 誤って本番ノードを終了させるリスクを排除する。
# ------------------------------------------------------------
resource "aws_iam_role" "fis_execution" {
  name = "${var.project}-fis-execution-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "fis.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = var.tags
}

resource "aws_iam_role_policy" "fis_execution" {
  name = "${var.project}-fis-execution-policy-${var.environment}"
  role = aws_iam_role.fis_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # EKS操作: クラスター情報の読み取りとKubernetes APIアクセス
        Sid    = "EKSAccess"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
          "eks:AccessKubernetesApi"
        ]
        Resource = "*"
      },
      {
        # EC2ノード終了: ChaosTarget=trueタグ付きノードのみに制限
        Sid    = "EC2TerminateChaosTargetOnly"
        Effect = "Allow"
        Action = ["ec2:TerminateInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/ChaosTarget" = "true"
          }
        }
      },
      {
        # StopCondition評価: CloudWatchアラーム状態の読み取り
        Sid    = "CloudWatchAlarmRead"
        Effect = "Allow"
        Action = ["cloudwatch:DescribeAlarms"]
        Resource = "*"
      },
      {
        # 実験ログ書き込み: FIS実験の詳細ログをCloudWatchに記録
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogDelivery",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Resource = "*"
      }
    ]
  })
}

# ------------------------------------------------------------
# ① Pod Kill実験テンプレート
# chaos-targetネームスペースの全Podを即時削除し、
# KubernetesのReplicaSetによる自己修復能力を検証する。
# ------------------------------------------------------------
resource "aws_fis_experiment_template" "pod_kill" {
  description = "Pod Kill: chaos-targetネームスペースの全Podを削除してKubernetesの自己修復能力を検証"
  role_arn    = aws_iam_role.fis_execution.arn

  # ノードCPU90%超過で自動停止
  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop_condition.arn
  }

  action {
    name        = "pod-kill"
    action_id   = "aws:eks:pod-delete"
    description = "chaos-targetネームスペースの全Podを削除"

    # "Pods"はaws:eks:pod-deleteが要求するターゲットパラメータ名
    target {
      key   = "Pods"
      value = "chaos-target-pods"
    }
  }

  # chaos-targetネームスペースのPodをNamespaceフィルターで絞り込む
  target {
    name           = "chaos-target-pods"
    resource_type  = "aws:eks:pod"
    selection_mode = "ALL"

    filter {
      path   = "Namespace"
      values = ["chaos-target"]
    }

    parameters = {
      clusterIdentifier = var.cluster_name
    }
  }

  tags = merge(var.tags, {
    ExperimentType = "pod-kill"
    Name           = "${var.project}-pod-kill-${var.environment}"
  })
}

# ------------------------------------------------------------
# ② Node Termination実験テンプレート
# chaosノードグループのノードを50%終了し、
# Karpenterによる自動ノード復旧とPod再スケジューリングを検証する。
# ChaosTarget=trueタグでchaosノードグループのみを対象とし、
# baselineノードグループへの誤適用を防止する。
# ------------------------------------------------------------
resource "aws_fis_experiment_template" "node_termination" {
  description = "Node Termination: chaosノードグループの50%のノードを終了してKarpenterの自動復旧を検証"
  role_arn    = aws_iam_role.fis_execution.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop_condition.arn
  }

  action {
    name        = "node-termination"
    action_id   = "aws:eks:terminate-nodegroup-instances"
    description = "chaosノードグループのノードを50%終了"

    target {
      key   = "Nodegroups"
      value = "chaos-nodegroup"
    }

    # 50%のノードを終了してフェイルオーバー動作を検証
    parameter {
      key   = "instanceTerminationPercentage"
      value = "50"
    }
  }

  # ChaosTarget=trueタグ付きのノードグループのみを対象にする
  target {
    name           = "chaos-nodegroup"
    resource_type  = "aws:eks:nodegroup"
    selection_mode = "ALL"

    resource_tag {
      key   = "ChaosTarget"
      value = "true"
    }

    parameters = {
      clusterIdentifier = var.cluster_name
    }
  }

  tags = merge(var.tags, {
    ExperimentType = "node-termination"
    Name           = "${var.project}-node-termination-${var.environment}"
  })
}

# ------------------------------------------------------------
# ③ Network Latency実験テンプレート
# Kubernetes Jobでtc netemコマンドを実行し、
# chaos-targetネームスペースのネットワークに100msの遅延を注入する。
# 60秒後にtc netemを削除して自動復旧させる設計。
# NET_ADMIN capabilityが必要なためsecurityContextを設定する。
# ------------------------------------------------------------
resource "aws_fis_experiment_template" "network_latency" {
  description = "Network Latency: tc netemでchaos-targetネームスペースに100ms遅延を注入してサービス品質劣化を検証"
  role_arn    = aws_iam_role.fis_execution.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop_condition.arn
  }

  action {
    name        = "inject-network-latency"
    action_id   = "aws:eks:inject-kubernetes-custom-resource"
    description = "K8s JobでtcnetemによりNW遅延100msを注入"

    target {
      key   = "Cluster"
      value = "chaos-cluster"
    }

    parameter {
      key   = "kubernetesApiVersion"
      value = "batch/v1"
    }

    parameter {
      key   = "kubernetesKind"
      value = "Job"
    }

    parameter {
      key   = "kubernetesNamespace"
      value = "chaos-target"
    }

    # Jobスペック: tc netemで100ms遅延注入→60秒維持→クリーンアップ
    parameter {
      key = "kubernetesSpec"
      value = jsonencode({
        metadata = {
          name = "network-latency-chaos"
        }
        spec = {
          ttlSecondsAfterFinished = 60
          template = {
            metadata = {
              labels = { app = "network-latency-chaos" }
            }
            spec = {
              restartPolicy = "Never"
              hostNetwork   = true
              containers = [
                {
                  name  = "network-latency"
                  image = "busybox:latest"
                  command = [
                    "sh", "-c",
                    "tc qdisc add dev eth0 root netem delay 100ms && echo 'Latency injected' && sleep 60 && tc qdisc del dev eth0 root netem && echo 'Latency removed'"
                  ]
                  securityContext = {
                    capabilities = {
                      add = ["NET_ADMIN"]
                    }
                  }
                }
              ]
            }
          }
        }
      })
    }

    # 実験の最大継続時間: 60秒後に自動終了
    parameter {
      key   = "maxDuration"
      value = "PT1M"
    }
  }

  target {
    name           = "chaos-cluster"
    resource_type  = "aws:eks:cluster"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Project"
      value = var.project
    }

    resource_tag {
      key   = "Environment"
      value = var.environment
    }

    parameters = {}
  }

  tags = merge(var.tags, {
    ExperimentType = "network-latency"
    Name           = "${var.project}-network-latency-${var.environment}"
  })
}

# ------------------------------------------------------------
# ④ CPU Stress実験テンプレート
# stress-ngでCPU使用率80%の負荷をchaos-targetノードに注入し、
# Podエビクション（CPU requestsを超えた場合）と
# KarpenterのNode追加スケールアウトを検証する。
# ------------------------------------------------------------
resource "aws_fis_experiment_template" "cpu_stress" {
  description = "CPU Stress: stress-ngでCPU80%負荷を注入してPodエビクションとKarpenterスケールアウトを検証"
  role_arn    = aws_iam_role.fis_execution.arn

  stop_condition {
    source = "aws:cloudwatch:alarm"
    value  = aws_cloudwatch_metric_alarm.fis_stop_condition.arn
  }

  action {
    name        = "inject-cpu-stress"
    action_id   = "aws:eks:inject-kubernetes-custom-resource"
    description = "stress-ngでCPU80%ストレスをchaos-targetノードに注入"

    target {
      key   = "Cluster"
      value = "chaos-cluster"
    }

    parameter {
      key   = "kubernetesApiVersion"
      value = "batch/v1"
    }

    parameter {
      key   = "kubernetesKind"
      value = "Job"
    }

    parameter {
      key   = "kubernetesNamespace"
      value = "chaos-target"
    }

    # Jobスペック: 全CPUコアに80%負荷を60秒間かける
    parameter {
      key = "kubernetesSpec"
      value = jsonencode({
        metadata = {
          name = "cpu-stress-chaos"
        }
        spec = {
          ttlSecondsAfterFinished = 60
          template = {
            metadata = {
              labels = { app = "cpu-stress-chaos" }
            }
            spec = {
              restartPolicy = "Never"
              containers = [
                {
                  name  = "cpu-stress"
                  image = "alexeiled/stress-ng:latest"
                  # --cpu 0はCPU数を自動検出、--cpu-load 80は使用率80%
                  command = ["stress-ng", "--cpu", "0", "--cpu-load", "80", "--timeout", "60s"]
                  resources = {
                    limits = {
                      cpu    = "500m"
                      memory = "128Mi"
                    }
                    requests = {
                      cpu    = "500m"
                      memory = "128Mi"
                    }
                  }
                }
              ]
            }
          }
        }
      })
    }

    parameter {
      key   = "maxDuration"
      value = "PT1M"
    }
  }

  target {
    name           = "chaos-cluster"
    resource_type  = "aws:eks:cluster"
    selection_mode = "COUNT(1)"

    resource_tag {
      key   = "Project"
      value = var.project
    }

    resource_tag {
      key   = "Environment"
      value = var.environment
    }

    parameters = {}
  }

  tags = merge(var.tags, {
    ExperimentType = "cpu-stress"
    Name           = "${var.project}-cpu-stress-${var.environment}"
  })
}

# =============================================================================
# CloudWatch Dashboard: カオスエンジニアリング可視化
# FIS実験・Pod再起動・ノードCPU・Step Functions成功率・Bedrockレイテンシを
# 1画面で確認できるダッシュボードを定義する。
# =============================================================================

resource "aws_cloudwatch_dashboard" "chaos" {
  dashboard_name = "${var.project}-chaos-dashboard-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        # FIS実験実行回数（成功/失敗/停止の推移）
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "FIS実験実行回数"
          region = var.region
          metrics = [
            ["AWS/FIS", "ExperimentsRunning", { stat = "Sum", label = "実行中" }],
            ["AWS/FIS", "ExperimentsCompleted", { stat = "Sum", label = "完了" }],
            ["AWS/FIS", "ExperimentsFailed", { stat = "Sum", label = "失敗", color = "#d62728" }]
          ]
          view   = "timeSeries"
          period = 300
        }
      },
      {
        # Pod再起動回数（Container Insights）
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "Pod再起動回数"
          region = var.region
          metrics = [
            ["ContainerInsights", "pod_number_of_container_restarts", "ClusterName", var.cluster_name, { stat = "Sum", label = "再起動数" }]
          ]
          view   = "timeSeries"
          period = 60
        }
      },
      {
        # ノードCPU使用率（全ノード）
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title  = "ノードCPU使用率"
          region = var.region
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name, { stat = "Average", label = "平均CPU%" }],
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.cluster_name, { stat = "Maximum", label = "最大CPU%", color = "#d62728" }]
          ]
          yAxis = { left = { min = 0, max = 100 } }
          view  = "timeSeries"
          period = 60
          annotations = {
            horizontal = [{ value = 90, label = "StopCondition閾値", color = "#d62728" }]
          }
        }
      },
      {
        # ポストモーテム生成成功率（Step Functions）
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ポストモーテム生成成功率（Step Functions）"
          region = var.region
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", "arn:aws:states:${var.region}:*:stateMachine:${var.project}-postmortem-workflow-${var.environment}", { stat = "Sum", label = "成功" }],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", "arn:aws:states:${var.region}:*:stateMachine:${var.project}-postmortem-workflow-${var.environment}", { stat = "Sum", label = "失敗", color = "#d62728" }]
          ]
          view   = "timeSeries"
          period = 300
        }
      },
      {
        # Bedrock呼び出しレイテンシ（ポストモーテム生成時間）
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Bedrockレイテンシ（bedrock-analyzer Lambda）"
          region = var.region
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "${var.project}-bedrock-analyzer-${var.environment}", { stat = "Average", label = "平均実行時間(ms)" }],
            ["AWS/Lambda", "Duration", "FunctionName", "${var.project}-bedrock-analyzer-${var.environment}", { stat = "p99", label = "p99実行時間(ms)", color = "#ff7f0e" }]
          ]
          view   = "timeSeries"
          period = 300
        }
      }
    ]
  })
}
