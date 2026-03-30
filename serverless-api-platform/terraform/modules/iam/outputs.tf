# terraform/modules/iam/outputs.tf

output "lambda_role_arns" {
  description = "Lambda 実行ロールの ARN マップ。キーは Lambda 関数の短縮名。"
  value = {
    for k, v in aws_iam_role.lambda : k => v.arn
  }
}
