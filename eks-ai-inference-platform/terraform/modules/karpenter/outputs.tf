output "irsa_arn" {
  description = "KarpenterコントローラーIRSAロールARN"
  # KarpenterのIRSAはeksモジュール側で管理しているため、このモジュールでは空文字を返す
  value = ""
}
