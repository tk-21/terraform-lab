output "crossplane_user_arn" {
  description = "Crossplane IAMユーザーのARN"
  value       = aws_iam_user.crossplane.arn
}

# アクセスキーは sensitive=true で保護する
# 取得後は以下のコマンドで K8s Secret に登録すること:
#   kubectl create secret generic aws-credentials \
#     -n crossplane-system \
#     --from-literal=credentials="[default]
#   aws_access_key_id=$(terraform output -raw access_key_id)
#   aws_secret_access_key=$(terraform output -raw secret_access_key)"
output "access_key_id" {
  description = "AWSアクセスキーID (K8s Secret 登録用)"
  value       = aws_iam_access_key.crossplane.id
  sensitive   = true
}

output "secret_access_key" {
  description = "AWSシークレットアクセスキー (K8s Secret 登録用)"
  value       = aws_iam_access_key.crossplane.secret
  sensitive   = true
}

# K8s Secret に登録する credentials ファイルの内容を生成する
output "k8s_secret_command" {
  description = "K8s Secret 登録コマンド (コピペ実行用)"
  value       = <<-EOT
    kubectl create secret generic aws-credentials \
      -n crossplane-system \
      --from-literal=credentials="[default]
    aws_access_key_id=${aws_iam_access_key.crossplane.id}
    aws_secret_access_key=${aws_iam_access_key.crossplane.secret}"
  EOT
  sensitive   = true
}
