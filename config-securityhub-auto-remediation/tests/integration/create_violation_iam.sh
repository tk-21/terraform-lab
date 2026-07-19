#!/bin/bash
# IAM MFA未設定 違反ユーザーを作成するスクリプト (テスト用)
# ⚠️ テスト後は必ず削除すること

set -euo pipefail

USERNAME="csar-test-violation-user-$(date +%s)"

echo "=== IAM違反ユーザー作成: ${USERNAME} ==="

# MFA未設定のIAMユーザーを作成する (違反状態)
aws iam create-user --user-name "${USERNAME}"

# コンソールアクセスを有効化する (MFAが必要になるケース)
aws iam create-login-profile \
  --user-name "${USERNAME}" \
  --password "TempPass123!" \
  --password-reset-required

echo "IAMユーザー作成完了: ${USERNAME} (MFA未設定=違反状態)"
echo ""
echo "定期評価のため24時間待つか、手動でConfig Rule評価をトリガー:"
echo "  aws configservice start-config-rules-evaluation --config-rule-names csar-iam-user-mfa-enabled"
echo ""
echo "数分後に評価結果を確認:"
echo "  aws configservice get-compliance-details-by-config-rule \\"
echo "    --config-rule-name csar-iam-user-mfa-enabled \\"
echo "    --compliance-types NON_COMPLIANT"
echo ""
echo "テスト後のクリーンアップ:"
echo "  aws iam delete-login-profile --user-name ${USERNAME}"
echo "  aws iam delete-user --user-name ${USERNAME}"
