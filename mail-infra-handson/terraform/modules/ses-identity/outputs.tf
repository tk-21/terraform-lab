output "email_identity_arn" {
  description = "SES Email IdentityのARN"
  value       = aws_sesv2_email_identity.domain.arn
}

output "verification_status" {
  description = "SESドメイン検証ステータス。SUCCESS になってから送信が可能になる"
  value       = aws_sesv2_email_identity.domain.verified_for_sending_status
}

output "dkim_tokens" {
  description = "DKIMトークン一覧（3つ）。Route 53 CNAMEレコードの確認用"
  value       = aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens
}
