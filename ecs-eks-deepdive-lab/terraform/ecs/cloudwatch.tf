# アプリログのロググループ（7日保持でコスト最小化）
resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/deepdive/api"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/deepdive/worker"
  retention_in_days = 7
}
