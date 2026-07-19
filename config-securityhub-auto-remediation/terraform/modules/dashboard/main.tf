# ===== CloudWatch Dashboard: CSAR修復状況可視化 =====
# EMFカスタムメトリクス (Lambda Powertools) + AWSマネージドメトリクスを統合表示する
resource "aws_cloudwatch_dashboard" "csar_main" {
  dashboard_name = "CSAR-AutoRemediation"

  dashboard_body = jsonencode({
    widgets = [
      # ─── 行1: 修復件数サマリー ───────────────────────────────────────────────

      # 修復成功数 (Lambda PowertoolsのEMFが "CSAR" namespaceへ書き込む)
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 8
        height = 6
        properties = {
          title   = "修復成功数 (24時間)"
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["CSAR", "RemediationSuccess", "service", "s3-remediation", { label = "S3 成功" }],
            ["CSAR", "RemediationSuccess", "service", "iam-remediation", { label = "IAM 成功" }],
            ["CSAR", "RemediationSuccess", "service", "sg-remediation", { label = "SG 成功" }],
            ["CSAR", "RemediationSuccess", "service", "rds-remediation", { label = "RDS 成功" }],
          ]
          period = 3600
          stat   = "Sum"
          region = "ap-northeast-1"
        }
      },

      # 修復失敗数 — DLQ深度と合わせて確認すること
      {
        type   = "metric"
        x      = 8
        y      = 0
        width  = 8
        height = 6
        properties = {
          title = "修復失敗数 (24時間)"
          view  = "timeSeries"
          metrics = [
            ["CSAR", "RemediationFailed", "service", "s3-remediation", { label = "S3 失敗", color = "#d62728" }],
            ["CSAR", "RemediationFailed", "service", "iam-remediation", { label = "IAM 失敗", color = "#ff7f0e" }],
            ["CSAR", "RemediationFailed", "service", "sg-remediation", { label = "SG 失敗", color = "#e377c2" }],
            ["CSAR", "RemediationFailed", "service", "rds-remediation", { label = "RDS 失敗", color = "#8c564b" }],
          ]
          period = 3600
          stat   = "Sum"
          region = "ap-northeast-1"
        }
      },

      # 手動対応必要件数 — IAM(直接ポリシー割当)とRDS(暗号化)は自動修復不可
      {
        type   = "metric"
        x      = 16
        y      = 0
        width  = 8
        height = 6
        properties = {
          title = "手動対応必要件数"
          view  = "timeSeries"
          metrics = [
            ["CSAR", "RemediationManualRequired", "service", "iam-remediation", { label = "IAM 手動対応" }],
            ["CSAR", "RemediationManualRequired", "service", "rds-remediation", { label = "RDS 手動対応" }],
          ]
          period = 3600
          stat   = "Sum"
          region = "ap-northeast-1"
        }
      },

      # ─── 行2: Lambdaエラー率 / DLQ ──────────────────────────────────────────

      # Lambdaエラー率 — S3修復のみ表示。他3関数は同パターンで追加可能
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "Lambda エラー率 (%) — 修復関数別"
          view  = "timeSeries"
          metrics = [
            [{ expression = "100*m1/(m1+m2)", label = "S3修復 エラー率 (%)", id = "e1" }],
            ["AWS/Lambda", "Errors", "FunctionName", "csar-remediation-s3", { id = "m1", visible = false }],
            ["AWS/Lambda", "Invocations", "FunctionName", "csar-remediation-s3", { id = "m2", visible = false }],
            [{ expression = "100*m3/(m3+m4)", label = "IAM修復 エラー率 (%)", id = "e2" }],
            ["AWS/Lambda", "Errors", "FunctionName", "csar-remediation-iam", { id = "m3", visible = false }],
            ["AWS/Lambda", "Invocations", "FunctionName", "csar-remediation-iam", { id = "m4", visible = false }],
          ]
          period = 300
          stat   = "Sum"
          yAxis  = { left = { min = 0, max = 100 } }
          region = "ap-northeast-1"
        }
      },

      # DLQ深度 — 1以上でアラームが発火する。修復失敗の蓄積を示す
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title = "DLQ メッセージ数 (未処理) — 0 が正常"
          view  = "timeSeries"
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", var.dlq_queue_name, { color = "#d62728" }],
          ]
          period = 300
          stat   = "Maximum"
          annotations = {
            horizontal = [{ value = 1, label = "要確認閾値", color = "#d62728" }]
          }
          region = "ap-northeast-1"
        }
      },

      # ─── 行3: 実行時間 / コールドスタート ────────────────────────────────────

      # P99実行時間 — 修復Lambdaタイムアウト300sに対するマージンを把握する
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Lambda 実行時間 P99 (ms)"
          view  = "timeSeries"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", "csar-remediation-s3", { stat = "p99", label = "S3" }],
            ["AWS/Lambda", "Duration", "FunctionName", "csar-remediation-iam", { stat = "p99", label = "IAM" }],
            ["AWS/Lambda", "Duration", "FunctionName", "csar-remediation-ec2-sg", { stat = "p99", label = "SG" }],
            ["AWS/Lambda", "Duration", "FunctionName", "csar-remediation-rds", { stat = "p99", label = "RDS" }],
          ]
          period = 3600
          annotations = {
            # タイムアウト300s = 300000ms のラインを表示
            horizontal = [{ value = 300000, label = "タイムアウト (300s)", color = "#d62728" }]
          }
          region = "ap-northeast-1"
        }
      },

      # コールドスタート数 — arm64+VPCの組み合わせではコールドスタートが長い傾向
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title = "Lambda コールドスタート数 (日次)"
          view  = "bar"
          metrics = [
            ["CSAR", "ColdStart", "service", "s3-remediation", { label = "S3" }],
            ["CSAR", "ColdStart", "service", "iam-remediation", { label = "IAM" }],
            ["CSAR", "ColdStart", "service", "sg-remediation", { label = "SG" }],
            ["CSAR", "ColdStart", "service", "rds-remediation", { label = "RDS" }],
          ]
          period = 86400
          stat   = "Sum"
          region = "ap-northeast-1"
        }
      },

      # ─── 行4: Config Rules コンプライアンス ──────────────────────────────────

      {
        type   = "metric"
        x      = 0
        y      = 18
        width  = 24
        height = 6
        properties = {
          title = "Config Rules 非準拠リソース数 (7日間)"
          view  = "timeSeries"
          metrics = [
            ["AWS/Config", "NonCompliantRuleCount", { label = "全ルール合計", color = "#d62728" }],
          ]
          period = 86400
          stat   = "Maximum"
          region = "ap-northeast-1"
        }
      },

      # ─── 運用メモ ──────────────────────────────────────────────────────────

      {
        type   = "text"
        x      = 0
        y      = 24
        width  = 24
        height = 4
        properties = {
          markdown = <<-EOT
            ## CSAR 運用メモ
            - **DLQ にメッセージがある場合**: `aws sqs receive-message --queue-url <DLQ_URL>` でメッセージ内容を確認し手動対応
            - **手動対応必要 (RDS暗号化)**: スナップショットから暗号化済みDBを復元後、旧DBを削除する
            - **手動対応必要 (IAM直接ポリシー)**: IAMグループを作成してポリシーを移管する
            - **Config評価の手動トリガー**: `aws configservice start-config-rules-evaluation --config-rule-names <rule-name>`
            - **修復成功率の計算**: RemediationSuccess / (RemediationSuccess + RemediationFailed) × 100
          EOT
        }
      }
    ]
  })
}
