resource "aws_sqs_queue" "dlq" {
  name = "csar-remediation-dlq"

  # Lambda修復関数がタイムアウト(300s)する間はメッセージを隠す
  # visibility_timeout > Lambda timeout でないと同一メッセージが二重処理される
  visibility_timeout_seconds = 360

  # 修復失敗メッセージを14日間保持し、手動調査・再処理に備える
  message_retention_seconds = 1209600

  # AWSマネージドキーによるSSE暗号化
  kms_master_key_id = "alias/aws/sqs"

  tags = {
    Name = "csar-remediation-dlq"
  }
}
