resource "aws_ssm_parameter" "chatwork_token" {
  name        = "/csar/chatwork/token"
  description = "Chatwork API Token (修復通知用)"
  type        = "SecureString"
  # 初期値はプレースホルダー。apply後に手動で上書きすること:
  # aws ssm put-parameter --name /csar/chatwork/token --value "実際のトークン" --type SecureString --overwrite
  value = "REPLACE_ME_CHATWORK_TOKEN"

  lifecycle {
    # terraform apply で値が上書きされないよう変更を無視する
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "chatwork_room_id" {
  name        = "/csar/chatwork/room_id"
  description = "Chatwork Room ID (修復通知先)"
  type        = "SecureString"
  value       = "REPLACE_ME_ROOM_ID"

  lifecycle {
    ignore_changes = [value]
  }
}
