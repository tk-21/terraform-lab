# =============================================================================
# SSMパラメータモジュール
# 設計思想: TerraformがパラメータをSSMに書き込み、Ansibleが読み取る
# これにより設定値がコードとして管理され、Ansibleのvarsファイルへのハードコードを防ぐ
# =============================================================================

resource "aws_ssm_parameter" "nginx_port" {
  name        = "/${var.name_prefix}/nginx/port"
  type        = "String"
  value       = tostring(var.nginx_port)
  description = "nginxリスンポート番号"
}

resource "aws_ssm_parameter" "nginx_worker_processes" {
  name        = "/${var.name_prefix}/nginx/worker_processes"
  type        = "String"
  value       = var.nginx_worker_processes
  description = "nginxワーカープロセス数（autoでCPUコア数に自動調整）"
}
