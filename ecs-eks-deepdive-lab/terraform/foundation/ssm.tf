# ECSタスク・EKS Podがシークレット・設定値を参照するSSMパラメータ
# ハードコード禁止: 環境変数はすべてSSM経由で取得する

resource "aws_ssm_parameter" "sqs_queue_url" {
  name  = "/deepdive/sqs-queue-url"
  type  = "String"
  value = aws_sqs_queue.job.url

  tags = { Name = "/deepdive/sqs-queue-url" }
}

