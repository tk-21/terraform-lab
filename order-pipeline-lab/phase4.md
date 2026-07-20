# Phase 4: Step Functions オーケストレーション

## 目標
Step Functions で注文処理フロー全体をオーケストレーションする。
Retry / Catch / 補償トランザクションパターンを実装し、障害耐性を面接で語れる状態にする。

## 処理フロー

```
[注文受付]
    │
    ▼
[在庫確認] ─── 在庫なし ──→ [注文キャンセル通知]
    │                              │
   OK                           失敗通知
    │
    ▼
[決済処理 (ECS Fargate)]
    │
    ├── 失敗 (Retry 3回)
    │       │
    │   まだ失敗
    │       ↓
    │   [決済失敗補償] → 在庫解放 → [失敗通知]
    │
   OK
    │
    ▼
[完了通知 (Lambda)]
    │
    ▼
[完了]
```

---

## 作成するリソース

```
step_functions/
└── order-pipeline.asl.json

terraform/modules/step_functions/
├── main.tf
├── variables.tf
└── outputs.tf
```

---

## Task 1: ASL (Amazon States Language) 定義

### `step_functions/order-pipeline.asl.json`

```json
{
  "Comment": "注文処理パイプライン - 障害耐性設計",
  "StartAt": "Initialize",
  "States": {

    "Initialize": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:putItem",
      "Parameters": {
        "TableName.$": "$.dynamodb_table_name",
        "Item": {
          "order_id":   { "S.$": "$.order_id" },
          "status":     { "S": "RECEIVED" },
          "amount":     { "N.$": "States.Format('{}', $.amount)" },
          "created_at": { "S.$": "$$.Execution.StartTime" }
        }
      },
      "ResultPath": null,
      "Next": "CheckInventory",
      "Retry": [{
        "ErrorEquals": ["States.TaskFailed"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "HandleError",
        "ResultPath": "$.error"
      }]
    },

    "CheckInventory": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName.$": "$.inventory_check_arn",
        "Payload": {
          "order_id.$": "$.order_id",
          "items.$":    "$.items"
        }
      },
      "ResultSelector": {
        "inventory_ok.$":   "$.Payload.inventory_ok",
        "reserved_items.$": "$.Payload.reserved_items",
        "reason.$":         "$.Payload.reason"
      },
      "ResultPath": "$.inventory_result",
      "Next": "IsInventoryOk",
      "Retry": [{
        "ErrorEquals": [
          "Lambda.ServiceException",
          "Lambda.TooManyRequestsException",
          "Lambda.SdkClientException"
        ],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0,
        "JitterStrategy": "FULL"
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "HandleError",
        "ResultPath": "$.error"
      }]
    },

    "IsInventoryOk": {
      "Type": "Choice",
      "Choices": [{
        "Variable":       "$.inventory_result.inventory_ok",
        "BooleanEquals":  true,
        "Next":           "ProcessPayment"
      }],
      "Default": "NotifyFailure"
    },

    "ProcessPayment": {
      "Type": "Task",
      "Resource": "arn:aws:states:::ecs:runTask.sync",
      "Parameters": {
        "LaunchType": "FARGATE",
        "Cluster.$":  "$.ecs_cluster_arn",
        "TaskDefinition.$": "$.task_definition_arn",
        "NetworkConfiguration": {
          "AwsvpcConfiguration": {
            "Subnets.$":        "$.private_subnet_ids",
            "SecurityGroups.$": "$.ecs_task_sg_ids",
            "AssignPublicIp":   "DISABLED"
          }
        },
        "Overrides": {
          "ContainerOverrides": [{
            "Name": "payment-processor",
            "Environment": [
              { "Name": "ORDER_ID",        "Value.$": "$.order_id" },
              { "Name": "AMOUNT",          "Value.$": "States.Format('{}', $.amount)" },
              { "Name": "RESERVED_ITEMS",  "Value.$": "States.JsonToString($.inventory_result.reserved_items)" },
              { "Name": "DYNAMODB_TABLE_NAME", "Value.$": "$.dynamodb_table_name" }
            ]
          }]
        },
        "CapacityProviderStrategy": [
          { "CapacityProvider": "FARGATE_SPOT", "Weight": 80 },
          { "CapacityProvider": "FARGATE",      "Weight": 20 }
        ]
      },
      "ResultPath": "$.payment_result",
      "Next": "NotifySuccess",
      "Retry": [{
        "ErrorEquals": ["ECS.EcsException", "States.TaskFailed"],
        "IntervalSeconds": 5,
        "MaxAttempts": 3,
        "BackoffRate": 2.0,
        "Comment": "なぜ: 決済は冪等性を担保した上で最大3回リトライ。FARGATE_SPOT 中断も考慮"
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "CompensatePayment",
        "ResultPath": "$.error",
        "Comment": "なぜ: 決済失敗時は在庫予約を解放する補償処理へ"
      }]
    },

    "CompensatePayment": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName.$": "$.notification_arn",
        "Payload": {
          "order_id.$": "$.order_id",
          "status":     "FAILED",
          "reason":     "決済処理に失敗しました。在庫の予約を解放します。"
        }
      },
      "ResultPath": null,
      "Next": "NotifyFailure",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException", "Lambda.TooManyRequestsException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "HandleError",
        "ResultPath": "$.error"
      }]
    },

    "NotifySuccess": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName.$": "$.notification_arn",
        "Payload": {
          "order_id.$": "$.order_id",
          "status":     "COMPLETED"
        }
      },
      "ResultPath": null,
      "Next": "OrderComplete",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException", "Lambda.TooManyRequestsException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "HandleError",
        "ResultPath": "$.error"
      }]
    },

    "NotifyFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::lambda:invoke",
      "Parameters": {
        "FunctionName.$": "$.notification_arn",
        "Payload": {
          "order_id.$": "$.order_id",
          "status":     "FAILED",
          "reason.$":   "$.inventory_result.reason"
        }
      },
      "ResultPath": null,
      "Next": "OrderFailed",
      "Retry": [{
        "ErrorEquals": ["Lambda.ServiceException", "Lambda.TooManyRequestsException"],
        "IntervalSeconds": 2,
        "MaxAttempts": 3,
        "BackoffRate": 2.0
      }],
      "Catch": [{
        "ErrorEquals": ["States.ALL"],
        "Next": "HandleError",
        "ResultPath": "$.error"
      }]
    },

    "HandleError": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName.$": "$.dynamodb_table_name",
        "Key": {
          "order_id": { "S.$": "$.order_id" }
        },
        "UpdateExpression": "SET #s = :status, error_detail = :err",
        "ExpressionAttributeNames": { "#s": "status" },
        "ExpressionAttributeValues": {
          ":status": { "S": "ERROR" },
          ":err":    { "S.$": "States.JsonToString($.error)" }
        }
      },
      "ResultPath": null,
      "Next": "OrderFailed"
    },

    "OrderComplete": {
      "Type": "Succeed"
    },

    "OrderFailed": {
      "Type": "Fail",
      "Error": "OrderProcessingFailed",
      "Cause": "注文処理が失敗しました。DynamoDB でステータスを確認してください。"
    }
  }
}
```

---

## Task 2: Step Functions Terraform モジュール

### `terraform/modules/step_functions/variables.tf`
```hcl
variable "project" { type = string }
variable "environment" { type = string }
variable "common_tags" { type = map(string) }
variable "inventory_check_arn" { type = string }
variable "notification_arn" { type = string }
variable "ecs_cluster_arn" { type = string }
variable "task_definition_arn" { type = string }
variable "ecs_task_sg_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "dynamodb_table_name" { type = string }
variable "dynamodb_table_arn" { type = string }
variable "orders_queue_arn" { type = string }
```

### `terraform/modules/step_functions/main.tf`

**IAM ロール (Step Functions 用)**
```hcl
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
        # ECS RunTask (なぜ: .sync 統合では ecs:RunTask + ecs:StopTask + ecs:DescribeTasks が必要)
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
        # EventBridge (なぜ: Step Functions の .sync 統合に必要)
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
```

**CloudWatch Log Group (Step Functions 実行ログ)**
```hcl
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aws/states/${var.project}-order-sfn"
  retention_in_days = 7
  tags              = var.common_tags
}
```

**Step Functions State Machine**
```hcl
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

  # なぜ: 実行ログを CloudWatch に出力することで、失敗した際の原因調査が容易になる
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = merge(var.common_tags, { Name = "${var.project}-order-sfn" })
}
```

**SQS → Step Functions トリガー Lambda**
```hcl
# SQS からメッセージを受け取り Step Functions を起動する Lambda
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
      STATE_MACHINE_ARN    = aws_sfn_state_machine.order_pipeline.arn
      INVENTORY_CHECK_ARN  = var.inventory_check_arn
      NOTIFICATION_ARN     = var.notification_arn
      ECS_CLUSTER_ARN      = var.ecs_cluster_arn
      TASK_DEFINITION_ARN  = var.task_definition_arn
      ECS_TASK_SG_ID       = var.ecs_task_sg_id
      PRIVATE_SUBNET_IDS   = join(",", var.private_subnet_ids)
      DYNAMODB_TABLE_NAME  = var.dynamodb_table_name
    }
  }

  tags = merge(var.common_tags, { Name = "${var.project}-sfn-trigger" })
}

# SQS → Lambda のイベントソースマッピング
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = var.orders_queue_arn
  function_name    = aws_lambda_function.sfn_trigger.arn
  batch_size       = 1  # なぜ: 1注文 = 1 Step Functions 実行で追跡しやすくする
}
```

**SQS Trigger Lambda コード (インライン生成)**
```hcl
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
    """SQS メッセージを受け取り Step Functions を起動する"""
    for record in event["Records"]:
        body = json.loads(record["body"])
        order_id = body["order_id"]

        # Step Functions に渡す入力を組み立てる
        sfn_input = {
            "order_id":          order_id,
            "amount":            body.get("amount", 0),
            "items":             body.get("items", []),
            "inventory_check_arn": os.environ["INVENTORY_CHECK_ARN"],
            "notification_arn":    os.environ["NOTIFICATION_ARN"],
            "ecs_cluster_arn":     os.environ["ECS_CLUSTER_ARN"],
            "task_definition_arn": os.environ["TASK_DEFINITION_ARN"],
            "ecs_task_sg_ids":   [os.environ["ECS_TASK_SG_ID"]],
            "private_subnet_ids": os.environ["PRIVATE_SUBNET_IDS"].split(","),
            "dynamodb_table_name": os.environ["DYNAMODB_TABLE_NAME"]
        }

        sfn.start_execution(
            stateMachineArn = os.environ["STATE_MACHINE_ARN"],
            # なぜ: order_id を実行名にすることで重複実行を検知できる
            name  = f"order-{order_id}",
            input = json.dumps(sfn_input)
        )

    return {"statusCode": 200}
PYTHON
  }
}
```

### `terraform/modules/step_functions/outputs.tf`
```hcl
output "state_machine_arn" { value = aws_sfn_state_machine.order_pipeline.arn }
output "state_machine_name" { value = aws_sfn_state_machine.order_pipeline.name }
output "sfn_trigger_function_name" { value = aws_lambda_function.sfn_trigger.function_name }
```

---

## Task 3: ADR 追加

### `docs/adr/adr-002-step-functions-retry.md`
```markdown
# ADR-002: Step Functions Retry / Catch 戦略

## Status
Accepted

## Context
[各ステートで異なるエラーが発生する可能性がある背景を書く]

## Decision
全 Task ステートに Retry ブロックを設定し、Lambda 系エラーと ECS 系エラーで
異なる IntervalSeconds を設定する。

## Consequences
[リトライによって何が保証されるか、冪等性との関係を書く]
```

### `docs/adr/adr-003-dlq-compensation.md`
```markdown
# ADR-003: DLQ + 補償トランザクション設計

## Status
Accepted

## Context
[SQS DLQ に届くケースと、補償処理が必要な理由を書く]

## Decision
maxReceiveCount=3 で DLQ に転送し、DLQ Lambda で補償処理（注文キャンセル）を実行する。

## Consequences
[補償処理の限界（冪等性の前提）と監視の重要性を書く]
```

---

## 実行手順

```bash
# Terraform 適用
cd terraform
terraform apply -auto-approve

# SQS に注文メッセージを投入して E2E テスト
aws sqs send-message \
  --queue-url $(terraform output -raw orders_queue_url) \
  --message-body '{
    "order_id": "order-e2e-001",
    "amount": 5000,
    "items": [
      {"sku": "A001", "qty": 2},
      {"sku": "B002", "qty": 1}
    ]
  }' \
  --region ap-northeast-1

# Step Functions 実行を確認
aws stepfunctions list-executions \
  --state-machine-arn $(terraform output -raw state_machine_arn) \
  --region ap-northeast-1 | jq '.executions[0]'

# DynamoDB でステータス確認
aws dynamodb get-item \
  --table-name order-pipeline-orders \
  --key '{"order_id": {"S": "order-e2e-001"}}' \
  --region ap-northeast-1 | jq '.Item.status.S'
```

---

## フェーズ完了チェックリスト

- [ ] `terraform apply` で State Machine が作成される
- [ ] SQS にメッセージを投入すると Step Functions が自動で起動する
- [ ] Step Functions コンソールで実行フローが可視化できる
- [ ] 正常ケース: DynamoDB に `COMPLETED` ステータスが書かれる
- [ ] 在庫なしケース (10%): `INVENTORY_FAILED` → `FAILED` のフローになる
- [ ] X-Ray トレースで各ステートの実行時間が見える
- [ ] ADR-002 / ADR-003 を自分の言葉で記述した

## 口頭説明チェック
「Retry の BackoffRate と JitterStrategy の役割」を説明できるか？
「補償トランザクションパターンとは何か、なぜ必要か」を説明できるか？
「Step Functions .sync 統合と Lambda 統合の違い」を説明できるか？