# Step Functions実行ログ用グループ
# 実行履歴をCloudWatchに送ることでデバッグ・監査を容易にする
resource "aws_cloudwatch_log_group" "sfn" {
  name              = "/aip/${var.env}/step-functions"
  retention_in_days = 14
}

resource "aws_sfn_state_machine" "inference_pipeline" {
  name     = "${var.name_prefix}-inference-pipeline"
  role_arn = var.sfn_role_arn
  type     = "STANDARD" # Expressより実行履歴保存期間が長い（90日）ためSTANDARDを選択

  definition = jsonencode({
    Comment = "AI推論パイプライン: ECS前処理 → Bedrock推論 → Chatwork通知"
    StartAt = "GenerateJobId"

    States = {
      # States.UUID()でジョブIDを採番し、後続ステートで一意キーとして利用する
      GenerateJobId = {
        Type = "Pass"
        Parameters = {
          "job_id.$"       = "States.UUID()"
          "s3_key.$"       = "$.s3_key"
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
                { "Name" = "S3_KEY", "Value.$" = "$.s3_key" },
                { "Name" = "JOB_ID", "Value.$" = "$.job_id" }
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

      # ECSタスクのjob_idからS3上の出力キーパスを組み立てる橋渡しステート
      ExtractOutputKey = {
        Type = "Pass"
        Parameters = {
          "job_id.$"     = "$.job_id"
          "output_key.$" = "States.Format('processed/{}.json', $.job_id)"
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
          # Bedrockのスロットリングに対してリトライ間隔を指数バックオフで拡大
          ErrorEquals     = ["Lambda.ServiceException", "Lambda.AWSLambdaException", "Lambda.SdkClientException", "Lambda.TooManyRequestsException"]
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
        ResultPath = null # 通知結果はパイプライン全体の出力に含めない
        End        = true
      }

      NotifyFailure = {
        Type     = "Task"
        Resource = "arn:aws:states:::lambda:invoke"
        Comment  = "パイプライン失敗をChatworkに通知し、ステートマシンをFail終了"
        Parameters = {
          FunctionName = var.lambda_notify_arn
          Payload = {
            "status"   = "failed"
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
    level                  = "ALL" # 全ステートの入出力を記録（デバッグ効率向上のため）
  }

  tracing_configuration {
    enabled = true # X-Rayトレースで各ステートのレイテンシを可視化
  }
}
