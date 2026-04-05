# =============================================================================
# workflow モジュール
#
# 役割:
#   S3 にレビュー対象ファイルがアップロードされたことをトリガーとして
#   Step Functions のマルチエージェントレビューワークフローを起動する。
#
# 構成コンポーネント:
#   1. workflow-starter Lambda
#      - S3 PUT イベントで起動
#      - ファイル内容を読み込んで Step Functions を StartExecution
#   2. S3 バケット通知（reviews/ プレフィックスへの PUT をトリガー）
#   3. Step Functions ステートマシン
#      - UpdateStatusRunning → Parallel（4 エージェント）→ Supervisor
#        → GenerateReport → SendNotification → UpdateStatusCompleted
#      - エラー時: ReviewFailed（ステータスを failed に更新）
#
# ステートマシン設計:
#   definition.asl.json にドキュメント用の ASL を記載。
#   実際の定義はこのファイルの jsonencode() で生成し、Lambda ARN を注入する。
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  workflow_starter_name = "${var.project_name}-workflow-starter-${var.environment}"
  state_machine_name    = "${var.project_name}-review-workflow-${var.environment}"
}

# =============================================================================
# workflow-starter Lambda パッケージ
# =============================================================================
data "archive_file" "workflow_starter_zip" {
  type        = "zip"
  source_file = "${path.module}/src/index.py"
  output_path = "${path.module}/dist/lambda.zip"
}

# =============================================================================
# IAM ロール: workflow-starter Lambda 実行ロール
# =============================================================================
resource "aws_iam_role" "workflow_starter_exec" {
  name = "${local.workflow_starter_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "lambda.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "workflow_starter_basic_execution" {
  role       = aws_iam_role.workflow_starter_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# S3 からファイルを読み込む権限
resource "aws_iam_role_policy" "workflow_starter_s3" {
  name = "s3-read-policy"
  role = aws_iam_role.workflow_starter_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${var.input_bucket_arn}/reviews/*"
      }
    ]
  })
}

# DynamoDB からセッション情報を取得 + ステータスを更新する権限
resource "aws_iam_role_policy" "workflow_starter_dynamodb" {
  name = "dynamodb-access-policy"
  role = aws_iam_role.workflow_starter_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:UpdateItem"
        ]
        Resource = var.review_table_arn
      }
    ]
  })
}

# Bedrock Vision/Document API 呼び出し権限
# アーキテクチャ図（PNG/JPG/PDF）を受け取ったとき、テキスト説明に変換するために使用
resource "aws_iam_role_policy" "workflow_starter_bedrock" {
  name = "bedrock-vision-policy"
  role = aws_iam_role.workflow_starter_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "bedrock:InvokeModel"
        Resource = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0"
      }
    ]
  })
}

# Step Functions の実行を起動する権限
resource "aws_iam_role_policy" "workflow_starter_sfn" {
  name = "sfn-start-execution-policy"
  role = aws_iam_role.workflow_starter_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "states:StartExecution"
        Resource = aws_sfn_state_machine.review_workflow.arn
      }
    ]
  })
}

# =============================================================================
# Lambda 関数: workflow-starter
# S3 PUT イベントを受けて Step Functions を起動する
# =============================================================================
resource "aws_lambda_function" "workflow_starter" {
  function_name = local.workflow_starter_name
  role          = aws_iam_role.workflow_starter_exec.arn
  runtime       = "python3.12"
  handler       = "index.lambda_handler"

  filename         = data.archive_file.workflow_starter_zip.output_path
  source_code_hash = data.archive_file.workflow_starter_zip.output_base64sha256

  memory_size = 256
  timeout     = 30

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.review_table_name
      STATE_MACHINE_ARN   = aws_sfn_state_machine.review_workflow.arn
      AWS_REGION_NAME     = data.aws_region.current.name
      # Week 4: 画像/PDF をテキストに変換するための Bedrock モデル
      BEDROCK_MODEL_ID    = "anthropic.claude-3-5-sonnet-20241022-v2:0"
    }
  }
}

resource "aws_cloudwatch_log_group" "workflow_starter_logs" {
  name              = "/aws/lambda/${local.workflow_starter_name}"
  retention_in_days = 90
}

# S3 が workflow-starter Lambda を呼び出すことを許可
resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.workflow_starter.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.input_bucket_arn
}

# =============================================================================
# S3 バケット通知
# reviews/ プレフィックスへの PUT をトリガーに workflow-starter を起動
# =============================================================================
resource "aws_s3_bucket_notification" "input_trigger" {
  bucket = var.input_bucket_id

  lambda_function {
    lambda_function_arn = aws_lambda_function.workflow_starter.arn
    events              = ["s3:ObjectCreated:Put"]
    filter_prefix       = "reviews/"
  }

  # Lambda 実行許可が先に作成されていないと S3 通知の登録が失敗する
  depends_on = [aws_lambda_permission.s3_invoke]
}

# =============================================================================
# IAM ロール: Step Functions 実行ロール
# Lambda 呼び出し + DynamoDB SDK 統合 + CloudWatch Logs
# =============================================================================
resource "aws_iam_role" "sfn_exec" {
  name = "${local.state_machine_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "states.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })
}

# 7 つの Lambda（4 エージェント + supervisor + report-generator + chatwork-notifier）を呼び出す権限
resource "aws_iam_role_policy" "sfn_lambda_invoke" {
  name = "lambda-invoke-policy"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "lambda:InvokeFunction"
        Resource = [
          var.security_reviewer_arn,
          var.cost_reviewer_arn,
          var.reliability_reviewer_arn,
          var.operations_reviewer_arn,
          var.supervisor_arn,
          var.report_generator_arn,
          var.chatwork_notifier_arn,
        ]
      }
    ]
  })
}

# DynamoDB UpdateItem（UpdateStatusRunning / UpdateStatusCompleted / ReviewFailed ステート）
resource "aws_iam_role_policy" "sfn_dynamodb" {
  name = "dynamodb-update-policy"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = var.review_table_arn
      }
    ]
  })
}

# CloudWatch Logs への実行ログ書き込み権限
# Step Functions は通常の logs:CreateLogGroup ではなく
# CreateLogDelivery 系 API を使用するため注意
resource "aws_iam_role_policy" "sfn_logs" {
  name = "cloudwatch-logs-policy"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = "*" # CreateLogDelivery 系 API はリソース指定不可
      }
    ]
  })
}

# X-Ray トレーシング権限
resource "aws_iam_role_policy" "sfn_xray" {
  name = "xray-policy"
  role = aws_iam_role.sfn_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets"
        ]
        Resource = "*"
      }
    ]
  })
}

# =============================================================================
# CloudWatch Log Group: Step Functions 実行ログ
# =============================================================================
resource "aws_cloudwatch_log_group" "sfn_logs" {
  name              = "/aws/states/${local.state_machine_name}"
  retention_in_days = 90
}

# =============================================================================
# Step Functions ステートマシン
#
# フロー:
#   UpdateStatusRunning
#     ↓
#   ParallelReview（security / cost / reliability / operations が同時実行）
#     ↓
#   SupervisorReview（4 エージェントの結果を統合・矛盾解消）
#     ↓
#   GenerateReport（HTML レポート生成 → S3 保存 → 署名付き URL 取得）
#     ↓
#   SendNotification（Chatwork にサマリー + レポートリンクを通知）
#     ↓
#   UpdateStatusCompleted
#
# エラーハンドリング:
#   ParallelReview・SupervisorReview・GenerateReport でエラーが発生した場合は
#   ReviewFailed ステートでステータスを "failed" に更新して終了する。
#   SendNotification は Chatwork 障害でも completed にする（通知失敗はノンブロッキング）。
# =============================================================================
resource "aws_sfn_state_machine" "review_workflow" {
  name     = local.state_machine_name
  role_arn = aws_iam_role.sfn_exec.arn
  type     = "STANDARD"

  # ステートマシン定義を jsonencode() で生成し Lambda ARN / テーブル名を注入する。
  # 可読性のある ASL ドキュメントは definition.asl.json を参照。
  definition = jsonencode({
    Comment = "AWS インフラレビュー AI - マルチエージェントレビューワークフロー"
    StartAt = "UpdateStatusRunning"
    States = {

      # ----------------------------------------------------------
      # セッションステータスを "running" に更新
      # ----------------------------------------------------------
      UpdateStatusRunning = {
        Type     = "Task"
        Comment  = "セッションステータスを pending → running に更新"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.review_table_name
          Key = {
            session_id = { "S.$" = "$.session_id" }
          }
          UpdateExpression          = "SET #st = :status"
          ExpressionAttributeNames  = { "#st" = "status" }
          ExpressionAttributeValues = { ":status" = { S = "running" } }
        }
        ResultPath = null
        Next       = "ParallelReview"
      }

      # ----------------------------------------------------------
      # 4 エージェントが並列でレビューを実行
      # 各ブランチは同一の入力（session_id / review_content / input_type）を受け取る
      # ResultPath で結果配列を $.agent_results に格納し元の入力を保持する
      # ----------------------------------------------------------
      ParallelReview = {
        Type    = "Parallel"
        Comment = "security / cost / reliability / operations の 4 エージェントが並列実行"
        Branches = [
          {
            StartAt = "SecurityReview"
            States = {
              SecurityReview = {
                Type     = "Task"
                Comment  = "IAM・暗号化・VPC エンドポイント・パブリック露出をレビュー"
                Resource = var.security_reviewer_arn
                End      = true
              }
            }
          },
          {
            StartAt = "CostReview"
            States = {
              CostReview = {
                Type     = "Task"
                Comment  = "リソーススペック・NAT Gateway・Savings Plans をレビュー"
                Resource = var.cost_reviewer_arn
                End      = true
              }
            }
          },
          {
            StartAt = "ReliabilityReview"
            States = {
              ReliabilityReview = {
                Type     = "Task"
                Comment  = "Single AZ・バックアップ・フェイルオーバー・RPO/RTO をレビュー"
                Resource = var.reliability_reviewer_arn
                End      = true
              }
            }
          },
          {
            StartAt = "OperationsReview"
            States = {
              OperationsReview = {
                Type     = "Task"
                Comment  = "タグ戦略・監視設計・ログ出力・デプロイ戦略をレビュー"
                Resource = var.operations_reviewer_arn
                End      = true
              }
            }
          }
        ]
        # agent_results は 4 要素の配列: [security結果, cost結果, reliability結果, operations結果]
        ResultPath = "$.agent_results"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReviewFailed"
            ResultPath  = "$.error"
          }
        ]
        Next = "SupervisorReview"
      }

      # ----------------------------------------------------------
      # スーパーバイザーが 4 エージェントの結果を統合
      # Parameters で必要なフィールドだけを選択して Lambda に渡す
      # ----------------------------------------------------------
      SupervisorReview = {
        Type    = "Task"
        Comment = "トレードオフ明示・優先アクション絞り込み・総合スコア算出"
        Resource = var.supervisor_arn
        Parameters = {
          "session_id.$"     = "$.session_id"
          "input_type.$"     = "$.input_type"
          "review_content.$" = "$.review_content"
          "agent_results.$"  = "$.agent_results"
        }
        ResultPath = "$.supervisor_result"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReviewFailed"
            ResultPath  = "$.error"
          }
        ]
        Next = "GenerateReport"
      }

      # ----------------------------------------------------------
      # HTML レポートを生成して S3 に保存
      # DynamoDB の final_report_url も更新する
      # ----------------------------------------------------------
      GenerateReport = {
        Type    = "Task"
        Comment = "HTML レポート生成 → S3 保存 → 署名付き URL 取得（7 日間有効）"
        Resource = var.report_generator_arn
        Parameters = {
          "session_id.$"        = "$.session_id"
          "input_type.$"        = "$.input_type"
          "s3_key.$"            = "$.s3_key"
          "agent_results.$"     = "$.agent_results"
          "supervisor_result.$" = "$.supervisor_result"
        }
        ResultPath = "$.report_result"
        Catch = [
          {
            ErrorEquals = ["States.ALL"]
            Next        = "ReviewFailed"
            ResultPath  = "$.error"
          }
        ]
        Next = "SendNotification"
      }

      # ----------------------------------------------------------
      # Chatwork にサマリー + レポートリンクを通知
      # 通知失敗はワークフローを止めない（chatwork-notifier が内部でエラーを吸収）
      # ----------------------------------------------------------
      SendNotification = {
        Type    = "Task"
        Comment = "Chatwork にレビュー完了通知（失敗してもワークフローは続行）"
        Resource = var.chatwork_notifier_arn
        Parameters = {
          "session_id.$"        = "$.session_id"
          "input_type.$"        = "$.input_type"
          "supervisor_result.$" = "$.supervisor_result"
          "report_url.$"        = "$.report_result.report_url"
          "report_s3_key.$"     = "$.report_result.report_s3_key"
        }
        ResultPath = "$.notification_result"
        Next       = "UpdateStatusCompleted"
        # Catch なし: chatwork-notifier は内部でエラーを吸収して status="error" を返す
      }

      # ----------------------------------------------------------
      # 全レビュー完了: ステータスを "completed" に更新
      # ----------------------------------------------------------
      UpdateStatusCompleted = {
        Type     = "Task"
        Comment  = "全レビュー完了後にステータスを completed に更新"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.review_table_name
          Key = {
            session_id = { "S.$" = "$.session_id" }
          }
          UpdateExpression          = "SET #st = :status"
          ExpressionAttributeNames  = { "#st" = "status" }
          ExpressionAttributeValues = { ":status" = { S = "completed" } }
        }
        ResultPath = null
        End        = true
      }

      # ----------------------------------------------------------
      # エラー時: ステータスを "failed" に更新して終了
      # ----------------------------------------------------------
      ReviewFailed = {
        Type     = "Task"
        Comment  = "エラー発生時にステータスを failed に更新して終了"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName = var.review_table_name
          Key = {
            session_id = { "S.$" = "$.session_id" }
          }
          UpdateExpression          = "SET #st = :status"
          ExpressionAttributeNames  = { "#st" = "status" }
          ExpressionAttributeValues = { ":status" = { S = "failed" } }
        }
        ResultPath = null
        End        = true
      }
    }
  })

  logging_configuration {
    # ":*" がないと CloudWatch Logs への書き込みが失敗する
    log_destination        = "${aws_cloudwatch_log_group.sfn_logs.arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  tracing_configuration {
    enabled = true
  }

  depends_on = [
    aws_iam_role_policy.sfn_lambda_invoke,
    aws_iam_role_policy.sfn_dynamodb,
    aws_iam_role_policy.sfn_logs,
    aws_iam_role_policy.sfn_xray,
  ]
}
