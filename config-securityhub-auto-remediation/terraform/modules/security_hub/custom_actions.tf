# Security Hub Custom Action: S3修復
# Finding一覧画面の「アクション」ドロップダウンに表示される手動トリガー
resource "aws_securityhub_action_target" "s3_remediate" {
  # Security Hub Action Targetのnameは20文字以下という制約があるためASCIIで統一
  name        = "CSAR: S3 Remediate"
  identifier  = "CSARRemediateS3"
  description = "S3バケットのPublic Access/暗号化違反を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# Security Hub Custom Action: IAM修復
resource "aws_securityhub_action_target" "iam_remediate" {
  name        = "CSAR: IAM Remediate"
  identifier  = "CSARRemediateIAM"
  description = "IAMユーザーのMFA未設定/過剰権限違反を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# Security Hub Custom Action: EC2/SG修復
resource "aws_securityhub_action_target" "sg_remediate" {
  name        = "CSAR: SG Remediate"
  identifier  = "CSARRemediateSG"
  description = "Security GroupのSSH/RDP 0.0.0.0/0開放を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# Security Hub Custom Action: RDS修復
# RDSはインプレース暗号化変更不可のため「監査ログ記録+スナップショット」のみ実施
resource "aws_securityhub_action_target" "rds_remediate" {
  name        = "CSAR: RDS Review"
  identifier  = "CSARRemediateRDS"
  description = "RDSの暗号化/Public Access違反を検知して手動対応として記録する"

  depends_on = [aws_securityhub_account.main]
}
