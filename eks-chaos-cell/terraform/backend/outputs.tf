output "tfstate_bucket_name" { value = aws_s3_bucket.tfstate.bucket }
output "tfstate_dynamodb_table" { value = aws_dynamodb_table.tfstate_lock.name }
output "github_actions_role_arn" { value = aws_iam_role.github_actions.arn }
