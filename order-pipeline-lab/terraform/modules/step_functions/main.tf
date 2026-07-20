# -------------------------------------------------------
# IAM ロール (Step Functions 用)
# -------------------------------------------------------

# なぜ: Step Functions が Lambda/ECS/DynamoDB を呼び出すための最小権限
data "aws_iam_policy_document" "sfn_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.project}-sfn-role"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume_role.json
  tags               = var.common_tags
}

resource "aws_iam_role_policy" "sfn" {
  name = "${var.project}-sfn-policy"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Lambda invoke
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [var.inventory_check_arn, var.notification_arn]
      },
      {
        # ECS RunTask
        # なぜ: .sync 統合では ecs:RunTask + ecs:StopTask + ecs:DescribeTasks が必要
        Effect = "Allow"
        Action = [
          "ecs:RunTask",
          "ecs:StopTask",
          "ecs:DescribeTasks"
        ]
        Resource = ["*"]
      },
      {
        # ECS タスクにロールを渡す
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = ["*"]
        Condition = {
          StringLike = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
      {
        # DynamoDB 直接アクセス (Initialize / HandleError ステート)
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = [var.dynamodb_table_arn]
      },
      {
        # X-Ray トレーシング
        Effect   = "Allow"
        Action   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
        Resource = ["*"]
      },
      {
        # EventBridge
        # なぜ: Step Functions の .sync 統合に必要。ECS タスク完了イベントを受信するため
        Effect   = "Allow"
        Action   = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
        Resource = ["arn:aws:events:ap-northeast-1:*:rule/StepFunctionsGetEventsForECSTaskRule"]
      },
      {
        # CloudWatch Logs (実行ログ出力)
        Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery",
          "logs:CreateLogGroup",
          "logs:GetLogDelivery",
          "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery",
          "logs:ListLogDeliveries",
          "logs:PutLogEvents",
          "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies",
          "logs:DescribeLogGroups"
        ]
        Resource = ["*"]
      }
    ]
  })
}

# -------------------------------------------------------
# IAM ロール (SQS Trigger Lambda 用)
# -------------------------------------------------------

resource "aws_iam_role" "sfn_trigger_lambda" {
  name = "${var.project}-sfn-trigger-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.common_tags
}

resource "aws_iam_role_policy" "sfn_trigger_lambda" {
  name = "${var.project}-sfn-trigger-policy"
  role = aws_iam_role.sfn_trigger_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Step Functions 実行開始
        Effect   = "Allow"
        Action   = ["states:StartExecution"]
        Resource = [aws_sfn_state_machine.order_pipeline.arn]
      },
      {
        # SQS メッセージ受信
        # なぜ: イベントソースマッピングによる SQS ポーリングに必要な最小権限
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [var.orders_queue_arn]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords"
        ]
        Resource = "*"
      }
    ]
  })
}

# -------------------------------------------------------
# CloudWatch Log Group (Step Functions 実行ログ)
# -------------------------------------------------------

# なぜ: 実行ログを CloudWatch に出力することで、失敗した際の原因調査が容易になる
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.project}-order-sfn"
  retention_in_days = 7

  tags = var.common_tags
}

resource "aws_cloudwatch_log_group" "sfn_trigger" {
  name              = "/aws/lambda/${var.project}-sfn-trigger"
  retention_in_days = 7

  tags = var.common_tags
}

# -------------------------------------------------------
# Step Functions State Machine
# -------------------------------------------------------

resource "aws_sfn_state_machine" "order_pipeline" {
  name     = "${var.project}-order-sfn"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile(
    "${path.root}/../step_functions/order-pipeline.asl.json",
    {}
  )

  # なぜ: X-Ray トレーシングで各ステートの実行時間・エラーを可視化
  tracing_configuration {
    enabled = true
  }

  # なぜ: ALL レベルで全ステート遷移を記録し、障害調査を確実にする
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = merge(var.common_tags, { Name = "${var.project}-order-sfn" })
}

# -------------------------------------------------------
# SQS → Step Functions トリガー Lambda
# -------------------------------------------------------

data "archive_file" "sfn_trigger" {
  type        = "zip"
  output_path = "${path.root}/../.build/sfn-trigger.zip"

  source {
    filename = "index.py"
    content  = <<-PYTHON
import os
import json
import boto3

sfn = boto3.client("stepfunctions")


def handler(event, context):
    for record in event["Records"]:
        body = json.loads(record["body"])
        order_id = body["order_id"]

        sfn_input = {
            "order_id":            order_id,
            "amount":              body.get("amount", 0),
            "items":               body.get("items", []),
            "inventory_check_arn": os.environ["INVENTORY_CHECK_ARN"],
            "notification_arn":    os.environ["NOTIFICATION_ARN"],
            "ecs_cluster_arn":     os.environ["ECS_CLUSTER_ARN"],
            "task_definition_arn": os.environ["TASK_DEFINITION_ARN"],
            "ecs_task_sg_ids":     [os.environ["ECS_TASK_SG_ID"]],
            "private_subnet_ids":  os.environ["PRIVATE_SUBNET_IDS"].split(","),
            "dynamodb_table_name": os.environ["DYNAMODB_TABLE_NAME"],
        }

        # なぜ: order_id を実行名にすることで同一注文の重複実行を検知できる
        sfn.start_execution(
            stateMachineArn=os.environ["STATE_MACHINE_ARN"],
            name=f"order-{order_id}",
            input=json.dumps(sfn_input),
        )

    return {"statusCode": 200}
PYTHON
  }
}

resource "aws_lambda_function" "sfn_trigger" {
  function_name = "${var.project}-sfn-trigger"
  role          = aws_iam_role.sfn_trigger_lambda.arn
  runtime       = "python3.12"
  architectures = ["arm64"]
  handler       = "index.handler"
  timeout       = 30

  filename         = data.archive_file.sfn_trigger.output_path
  source_code_hash = data.archive_file.sfn_trigger.output_base64sha256

  environment {
    variables = {
      STATE_MACHINE_ARN   = aws_sfn_state_machine.order_pipeline.arn
      INVENTORY_CHECK_ARN = var.inventory_check_arn
      NOTIFICATION_ARN    = var.notification_arn
      ECS_CLUSTER_ARN     = var.ecs_cluster_arn
      TASK_DEFINITION_ARN = var.task_definition_arn
      ECS_TASK_SG_ID      = var.ecs_task_sg_id
      PRIVATE_SUBNET_IDS  = join(",", var.private_subnet_ids)
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.sfn_trigger,
    aws_iam_role_policy.sfn_trigger_lambda
  ]

  tags = merge(var.common_tags, { Name = "${var.project}-sfn-trigger" })
}

# なぜ: batch_size=1 で 1注文 = 1 Step Functions 実行とし、追跡・デバッグを容易にする
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = var.orders_queue_arn
  function_name    = aws_lambda_function.sfn_trigger.arn
  batch_size       = 1
}
