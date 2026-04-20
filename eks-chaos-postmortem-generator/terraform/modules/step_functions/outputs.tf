# =============================================================================
# Step Functionsモジュール アウトプット定義
# =============================================================================

output "state_machine_arn" {
  description = "ポストモーテムワークフロー ステートマシンのARN（fis-event-handler Lambda環境変数に設定）"
  value       = aws_sfn_state_machine.postmortem.arn
}

output "state_machine_name" {
  description = "ステートマシン名（CloudWatchダッシュボードの参照用）"
  value       = aws_sfn_state_machine.postmortem.name
}
