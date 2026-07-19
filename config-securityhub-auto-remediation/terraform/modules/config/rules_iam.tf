# IAMユーザーMFA有効化チェックルール
# IAMはグローバルリソースのため scope なし — 全IAMユーザーが対象
# 変更ドリブン評価ではなく定期評価: MFA設定はリソース変更として記録されないため
resource "aws_config_config_rule" "iam_user_mfa_enabled" {
  name        = "csar-iam-user-mfa-enabled"
  description = "IAMユーザーにMFAが有効化されていることを確認する"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_MFA_ENABLED"
  }

  # 24時間ごとに全IAMユーザーを評価する (変更ドリブンではない)
  maximum_execution_frequency = "TwentyFour_Hours"

  depends_on = [aws_config_configuration_recorder_status.main]
}

# IAMユーザーへの直接ポリシーアタッチ禁止ルール
# グループ/ロール経由のポリシー付与が正しい設計
resource "aws_config_config_rule" "iam_no_inline_policy" {
  name        = "csar-iam-user-no-policies-check"
  description = "IAMユーザーへのインラインポリシー直接アタッチを禁止する"

  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_NO_POLICIES_CHECK"
  }

  scope {
    compliance_resource_types = ["AWS::IAM::User"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}
