variable "project" {
  description = "プロジェクトプレフィックス"
  type        = string
}

variable "env" {
  description = "環境名"
  type        = string
}

variable "webacl_name" {
  description = "WAF WebACL 名 (CloudWatch メトリクスのディメンションに使用)"
  type        = string
}

variable "chatwork_room_id" {
  description = "Chatwork 通知先 Room ID"
  type        = string
}

variable "waf_block_threshold" {
  description = "WAF ブロック数アラーム閾値 (5 分間)"
  type        = number
  default     = 100
}

variable "powertools_layer_version" {
  description = "Lambda Powertools for Python レイヤーバージョン番号"
  type        = number
  default     = 7
}
