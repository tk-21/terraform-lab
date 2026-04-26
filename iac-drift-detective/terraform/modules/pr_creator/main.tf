# pr-creator Lambda関数のデプロイ定義
# GitHub API操作・Chatwork通知を行うためタイムアウト60秒・メモリ256MBで設定

locals {
  source_dir  = "${path.module}/../../../lambda/pr_creator"
  output_path = "${path.module}/../../../lambda/pr_creator.zip"
}

# Lambdaデプロイ用ZIPアーカイブを作成する
data "archive_file" "pr_creator" {
  type        = "zip"
  source_dir  = local.source_dir
  output_path = local.output_path
}

resource "aws_lambda_function" "pr_creator" {
  function_name = "drift-detective-pr-creator"
  description   = "Bedrockが生成した修復HCLをGitHub PRとして作成しChatworkに通知する"
  role          = var.lambda_role_arn
  handler       = "index.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]
  # GitHub API・Chatwork APIの呼び出しを含むため60秒に設定
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.pr_creator.output_path
  source_code_hash = data.archive_file.pr_creator.output_base64sha256

  environment {
    variables = {
      GITHUB_OWNER            = var.github_owner
      GITHUB_REPO             = var.github_repo
      CHATWORK_ROOM_ID        = var.chatwork_room_id
      POWERTOOLS_SERVICE_NAME = "pr-creator"
      LOG_LEVEL               = "INFO"
    }
  }

  logging_config {
    log_format = "JSON"
    log_group  = var.log_group_name
  }

  tags = merge(var.tags, { Name = "drift-detective-pr-creator" })
}
