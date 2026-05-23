# ✅Phase 4 — Step Functions ステートマシン定義

## 目標
- ECSタスク（前処理）→ Lambda（Bedrock推論）→ Lambda（Chatwork通知）を
  Step Functionsで orchestrate するステートマシンを作成する
- エラー時のリトライ・フォールバック処理を定義する
- CloudWatch Logsへの実行履歴記録を有効化する

---

## タスク一覧

### 4-1. Step Functionsモジュール作成

`terraform/modules/step_functions/main.tf`:

```hcl
# Step Functions実行ログ用グループ
# 実行履歴をCloudWatchに送ることでデバッグ・監査を容易にする
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aip/${var.env}/step-functions"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "inference_pipeline" {
  name     = "${var.name_prefix}-inference-pipeline"
  role_arn = var.sfn_role_arn
  type     = "STANDARD"  # Expressより高い実行履歴保存期間（90日）のためSTANDARDを選択

  definition = jsonencode({
    Comment = "AI推論パイプライン: ECS前処理 → Bedrock推論 → Chatwork通知"
    StartAt = "GenerateJobId"

    States = {
      # UUIDをジョブIDとして生成（States.UUIDは組み込み関数）
      GenerateJobId = {
        Type = "Pass"
        Parameters = {
          "job_id.$"    = "States.UUID()"
          "s3_key.$"    = "$.s3_key"
          "input_bucket.$" = "$.input_bucket"
        }
        Next = "RunPreprocessor"
      }

      RunPreprocessor = {
        Type     = "Task"
        Resource = "arn:aws:states:::ecs:runTask.sync:2"
        Comment  = "ECS Fargateで前処理コンテナを起動し、完了を同期待機する"
        Parameters = {
          LaunchType     = "FARGATE"
          Cluster        = var.ecs_cluster_arn
          TaskDefinition = var.task_definition_arn
          NetworkConfiguration = {
            AwsvpcConfiguration = {
              Subnets        = var.private_subnet_ids
              SecurityGroups = [var.ecs_security_group_id]
              AssignPublicIp = "DISABLED"
            }
          }
          # タスクに動的パラメータを環境変数として渡す
          Overrides = {
            ContainerOverrides = [{
              Name = "preprocessor"
              Environment = [
                { "Name" = "S3_KEY",   "Value.$" = "$.s3_key" }
                { "Name" = "JOB_ID",   "Value.$" = "$.job_id" }
              ]
            }]
          }
        }
        # ECSタスクの完了結果とjob_idを次のステートに引き継ぐ
        ResultPath = "$.ecs_result"
        Next       = "ExtractOutputKey"

        Retry = [{
          ErrorEquals     = ["ECS.AmazonECSException", "States.TaskFailed"]
          IntervalSeconds = 30
          MaxAttempts     = 2
          BackoffRate     = 2.0
        }]

        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.error"
        }]
      }

      # ECSタスクの環境変数からoutput_keyを取得する橋渡しステート
      ExtractOutputKey = {
        Type = "Pass"
        Parameters = {
          "job_id.$"      = "$.job_id"
          "output_key.$"  = "States.Format('processed/{}.json', $.job_id)"
        }
        Next = "InvokeBedrock"
      }

      InvokeBedrock = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Comment  = "Bedrock Claude Haikuで前処理済みデータを推論"
        Parameters = {
          FunctionName = var.lambda_bedrock_arn
          "Payload.$"  = "$"
        }
        ResultSelector = {
          "status.$"           = "$.Payload.status"
          "job_id.$"           = "$.Payload.job_id"
          "inference_result.$" = "$.Payload.inference_result"
        }
        ResultPath = "$"
        Next       = "NotifySuccess"

        Retry = [{
          # Bedrockのスロットリングに対してリトライ
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException",
                             "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
          IntervalSeconds = 10
          MaxAttempts     = 3
          BackoffRate     = 2.0
        }]

        Catch = [{
          ErrorEquals = ["States.ALL"]
          Next        = "NotifyFailure"
          ResultPath  = "$.error"
        }]
      }

      NotifySuccess = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Comment  = "パイプライン成功をChatworkに通知"
        Parameters = {
          FunctionName = var.lambda_notify_arn
          Payload = {
            "status.$"           = "$.status"
            "job_id.$"           = "$.job_id"
            "inference_result.$" = "$.inference_result"
          }
        }
        ResultPath = null  # 通知結果はパイプライン全体の出力に含めない
        End        = true
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Comment  = "パイプライン失敗をChatworkに通知し、ステートマシンをFail終了"
        Parameters = {
          FunctionName = var.lambda_notify_arn
          Payload = {
            "status" = "failed"
            "job_id.$" = "$.job_id"
            "error.$"  = "$.error"
          }
        }
        ResultPath = null
        Next       = "PipelineFailed"
      }

      PipelineFailed = {
        Type  = "Fail"
        Error = "PipelineExecutionFailed"
        Cause = "推論パイプラインでエラーが発生しました。CloudWatch Logsを確認してください。"
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn.arn}:*"
    include_execution_data = true
    level                  = "ALL"  # 全ステートの入出力を記録（デバッグ効率向上のため）
  }

  tracing_configuration {
    enabled = true  # X-Rayトレースで各ステートのレイテンシを可視化
  }
}
```

`terraform/modules/step_functions/variables.tf`:

```hcl
variable "name_prefix"            { type = string }
variable "env"                     { type = string }
variable "sfn_role_arn"            { type = string }
variable "ecs_cluster_arn"         { type = string }
variable "task_definition_arn"     { type = string }
variable "private_subnet_ids"      { type = list(string) }
variable "ecs_security_group_id"   { type = string }
variable "lambda_bedrock_arn"      { type = string }
variable "lambda_notify_arn"       { type = string }
```

`terraform/modules/step_functions/outputs.tf`:

```hcl
output "state_machine_arn"  { value = aws_sfn_state_machine.inference_pipeline.arn }
output "state_machine_name" { value = aws_sfn_state_machine.inference_pipeline.name }
```

---

### 4-2. ECS用セキュリティグループをECSモジュールに追加

`terraform/modules/ecs/main.tf` に追記:

```hcl
resource "aws_security_group" "ecs_task" {
  name        = "${var.name_prefix}-ecs-task-sg"
  description = "ECS前処理タスク用 - アウトバウンドのみ（VPC Endpoint経由でS3通信）"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

`terraform/modules/ecs/variables.tf` に追記:

```hcl
variable "vpc_id" { type = string }
```

`terraform/modules/ecs/outputs.tf` に追記:

```hcl
output "ecs_security_group_id" { value = aws_security_group.ecs_task.id }
```

---

### 4-3. environments/dev/main.tf にStep FunctionsとIAM更新

```hcl
module "step_functions" {
  source                = "../../modules/step_functions"
  name_prefix           = local.name_prefix
  env                   = var.env
  sfn_role_arn          = module.iam.sfn_role_arn
  ecs_cluster_arn       = module.ecs.cluster_arn
  task_definition_arn   = module.ecs.task_definition_arn
  private_subnet_ids    = var.private_subnet_ids
  ecs_security_group_id = module.ecs.ecs_security_group_id
  lambda_bedrock_arn    = module.lambda.invoke_bedrock_arn
  lambda_notify_arn     = module.lambda.notify_chatwork_arn
}
```

IAMモジュールの `sfn_arn` を更新:

```hcl
# module "iam" の sfn_arn を以下に変更
sfn_arn = module.step_functions.state_machine_arn
```

---

### 4-4. Apply + ステートマシン手動テスト

```bash
cd terraform/environments/dev
terraform apply -auto-approve

# Step Functions の ARN を取得
SFN_ARN=$(terraform output -raw state_machine_arn 2>/dev/null || \
  aws stepfunctions list-state-machines --query 'stateMachines[?contains(name,`aip-dev`)].stateMachineArn' --output text)

# テスト用ファイルをまずアップロード
bash ../../../scripts/upload_test_data.sh

# アップロードしたファイル名を確認
INPUT_BUCKET=$(terraform output -raw input_bucket_name)
S3_KEY=$(aws s3 ls "s3://$INPUT_BUCKET/input/" | tail -1 | awk '{print "input/"$4}')

# ステートマシンを手動実行
EXECUTION_ARN=$(aws stepfunctions start-execution \
  --state-machine-arn "$SFN_ARN" \
  --input "{\"s3_key\": \"$S3_KEY\", \"input_bucket\": \"$INPUT_BUCKET\"}" \
  --query 'executionArn' --output text)

echo "実行ARN: $EXECUTION_ARN"

# 実行ステータスを確認（完了まで待機）
watch -n 5 "aws stepfunctions describe-execution \
  --execution-arn '$EXECUTION_ARN' \
  --query '{status: status, start: startDate, stop: stopDate}'"
```

---

### 4-5. DynamoDB結果確認

```bash
# DynamoDBに推論結果が保存されているか確認
aws dynamodb scan \
  --table-name aip-dev-results \
  --region ap-northeast-1 \
  --query 'Items[0]'
```

---

## 完了チェックリスト

- [ ] ステートマシン `aip-dev-inference-pipeline` が作成されている
- [ ] 手動実行が `SUCCEEDED` で完了する
- [ ] DynamoDBにレコードが存在し `status = "completed"` になっている
- [ ] CloudWatch Logsにステートマシンの実行ログが記録されている
- [ ] Chatworkに完了通知が届いている（SSMトークン設定済みの場合）

## 口頭説明チェックポイント
- 「Step FunctionsのSTANDARDとEXPRESSの違いと使い分けは？」
- 「`ecs:runTask.sync:2` の `.sync` が意味することは？」
- 「Retryブロックで BackoffRate を設定する理由は？」
- 「ResultPathに `null` を指定するとどうなるか？」