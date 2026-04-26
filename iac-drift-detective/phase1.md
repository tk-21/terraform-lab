# ✅Phase 1: ベースインフラ構築
# IaC Drift Detective - Terraform × Bedrock × GitHub PR自動化
#
# 【このフェーズの目的】
# Terraformでベースとなるインフラリソースを構築する。
# Lambda・Step FunctionsはPhase2以降で実装するため、ここではIAMロール・
# S3・EventBridge・SSMパラメータ・Secrets設定のみを対象とする。
#
# 【実行方法】
# claude < phase1.md
#
# 【プロジェクト概要（CLAUDE.mdより）】
# - Terraform stateと実環境のドリフトをBedrockが分析し、修復PRを自動作成
# - Lambda: drift-detector / bedrock-analyzer / pr-creator (Python 3.12, arm64)
# - Bedrock: Claude Sonnet 3.5 (us-east-1)
# - 通知: Chatwork API
# - リージョン: ap-northeast-1 (Tokyo)
# - タグ: Project=iac-drift-detective, ManagedBy=terraform
# ============================================================

以下のファイルを作成してください。CLAUDE.mdの設計方針・禁止事項・命名規則を厳守すること。

## 作成対象ファイル

### terraform/backend.tf
```
S3バックエンド設定（バケット名・DynamoDBテーブル名は変数化）
```

### terraform/variables.tf
```
以下の変数を定義:
- aws_region (default: "ap-northeast-1")
- bedrock_region (default: "us-east-1")
- environment (default: "dev")
- project_name (default: "iac-drift-detective")
- github_owner (説明: GitHubユーザー名またはOrg名)
- github_repo (説明: 対象リポジトリ名)
- chatwork_room_id (説明: Chatwork通知先ルームID)
- monitored_tfstate_bucket (説明: 監視対象のtfstateが保存されているS3バケット)
- monitored_tfstate_key (説明: 監視対象のtfstateのS3キー)
```

### terraform/main.tf
```
以下のリソースを定義:
1. S3バケット (drift-detective-reports-${data.aws_caller_identity.current.account_id})
   - バージョニング有効
   - パブリックアクセスブロック有効
   - ライフサイクルポリシー: 90日後にGlacierへ移行、365日後に削除
   - タグ付与

2. IAMロール: drift-detective-detector-role
   - Lambda信頼ポリシー
   - インラインポリシー:
     * s3:GetObject (監視対象tfstateバケット)
     * config:DescribeConfigurationRecorders, config:GetResourceConfigHistory
     * cloudformation:DetectStackDrift, cloudformation:DescribeStackDriftDetectionStatus
     * logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents

3. IAMロール: drift-detective-analyzer-role
   - Lambda信頼ポリシー
   - インラインポリシー:
     * bedrock:InvokeModel (us-east-1, Claude Sonnet 3.5のみ)
     * s3:PutObject (reportsバケット)
     * logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents

4. IAMロール: drift-detective-pr-creator-role
   - Lambda信頼ポリシー
   - インラインポリシー:
     * ssm:GetParameter (パス: /drift-detective/*)
     * s3:GetObject (reportsバケット)
     * logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents

5. IAMロール: drift-detective-sfn-role
   - Step Functions信頼ポリシー
   - Lambda呼び出し権限 (3関数)
   - CloudWatch Logs書き込み権限

6. EventBridge Rule: drift-detective-schedule
   - cron(0 0 * * ? *)  # 毎日09:00 JST = 00:00 UTC
   - ターゲット: Step Functions (drift-detective-sfn-roleで実行)

7. SSMパラメータ (SecureString):
   - /drift-detective/github-token (description付き、値は"PLACEHOLDER"で作成)
   - /drift-detective/chatwork-api-token (description付き、値は"PLACEHOLDER"で作成)

8. CloudWatch Logs グループ (3Lambda分 + Step Functions分)
   - 保持期間: 30日
```

### terraform/outputs.tf
```
- reports_bucket_name
- detector_role_arn
- analyzer_role_arn
- pr_creator_role_arn
- sfn_role_arn
- eventbridge_rule_arn
```

### terraform/environments/dev/main.tf
```
ルートモジュールを呼び出すdev環境エントリーポイント
```

### terraform/environments/dev/terraform.tfvars
```
environment = "dev"
github_owner = "YOUR_GITHUB_USERNAME"
github_repo  = "iac-drift-detective"
chatwork_room_id = "YOUR_ROOM_ID"
monitored_tfstate_bucket = "YOUR_TFSTATE_BUCKET"
monitored_tfstate_key    = "terraform.tfstate"
```

## 制約・注意事項

- `data "aws_caller_identity" "current" {}` を使ってアカウントIDを動的取得すること
- IAMポリシーのResourceは可能な限り絞ること（`*` 使用禁止。ただし logs は `arn:aws:logs:*:*:*` 可）
- Bedrockのモデル ARN は `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0` を使用
- 全リソースにCLAUDE.mdのタグ戦略を適用すること
- Terraformバージョン制約: `required_version = ">= 1.9.0"`
- AWSプロバイダーバージョン: `~> 5.0`
- コメントは日本語で設計意図を記載すること

## 完了確認

Phase 1完了後、以下を確認:
- [ ] `terraform fmt` でフォーマットエラーなし
- [ ] `terraform validate` でバリデーションエラーなし
- [ ] 全IAMロールのインラインポリシーにワイルドカード`*`がないこと
- [ ] SSMパラメータが SecureString タイプであること