# ─── ECS タスクが Proxy に接続するための IAM ポリシー ─────────
# このポリシーは Phase 5 の ECS モジュールの Task Role にアタッチする

resource "aws_iam_policy" "app_rds_connect" {
  name        = "${var.prefix}-app-rds-connect-policy"
  description = "ECS Fargateタスクが RDS Proxy に IAM 認証で接続するための最小権限ポリシー"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "RDSProxyConnect"
        Effect = "Allow"
        Action = ["rds-db:connect"]
        # リソース形式: arn:aws:rds-db:{region}:{account}:dbuser:{proxy-resource-id}/{db-user}
        # proxy ARN ではなく proxy resource ID を使う点に注意
        Resource = [
          "arn:aws:rds-db:${var.aws_region}:${var.aws_account_id}:dbuser:${aws_db_proxy.main.arn}/*"
        ]
      }
    ]
  })
}

output "app_rds_connect_policy_arn" {
  description = "ECS Task Role にアタッチする RDS Proxy 接続ポリシー ARN"
  value       = aws_iam_policy.app_rds_connect.arn
}
