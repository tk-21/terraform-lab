# ✅Phase 1: ベースインフラ構築
# Ansible Playbook AI Reviewer
#
# 【このフェーズの目的】
# Terraform で Lambda・API Gateway・IAM・SSM を構築する
# Lambdaのコード実装はPhase2で行う
#
# 【プロジェクト概要（CLAUDE.mdより）】
# - GitHub Actions CI/CDでAnsible Playbookを Bedrock (Claude Sonnet)が自動レビュー
# - PRにMarkdownコメントとして投稿、重大度別ラベル付与
# - API Gateway → Lambda → Bedrock → GitHub API の構成
# - リージョン: ap-northeast-1 / Bedrock: us-east-1
# - タグ: Project=ansible-playbook-ai-reviewer, ManagedBy=terraform
#
# 【実行方法】
# claude < phase1.md
# ============================================================

以下のファイルを作成してください。CLAUDE.mdの設計方針・命名規則を厳守すること。

## 作成対象ファイル

### terraform/backend.tf
```
S3バックエンド設定（変数化）
```

### terraform/variables.tf
```
以下の変数を定義:
- aws_region (default: "ap-northeast-1")
- bedrock_region (default: "us-east-1")
- environment (default: "dev")
- project_name (default: "ansible-playbook-ai-reviewer")
- github_token_ssm_path (default: "/ansible-ai-reviewer/github-token")
- api_gateway_stage (default: "v1")
- lambda_timeout (default: 300)
- lambda_memory (default: 512)
```

### terraform/modules/reviewer_lambda/main.tf
```hcl
# playbook-reviewer Lambda の定義
# - aws_lambda_function:
#   * function_name: "ansible-ai-reviewer"
#   * runtime: python3.12
#   * architectures: ["arm64"]
#   * timeout: var.timeout (300)
#   * memory_size: var.memory (512)
#   * handler: "index.handler"
#   * ソース: placeholder zip（Phase2でコードをデプロイ）
#   * 環境変数:
#     - GITHUB_TOKEN_SSM_PATH
#     - BEDROCK_REGION
#     - POWERTOOLS_SERVICE_NAME = "ansible-ai-reviewer"
#     - LOG_LEVEL = "INFO"
# - aws_lambda_function_url は使わずAPI Gateway経由のみ
# - aws_cloudwatch_log_group (保持期間: 30日)
```

### terraform/modules/reviewer_lambda/variables.tf
```
必要な変数を定義
```

### terraform/modules/reviewer_lambda/outputs.tf
```
- lambda_arn
- lambda_invoke_arn
- lambda_function_name
```

### terraform/modules/api_gateway/main.tf
```hcl
# REST API Gateway の定義
# - aws_api_gateway_rest_api: "ansible-ai-reviewer-api"
# - リソース: /review
# - メソッド: POST
#   * 認証: API Key必須 (api_key_required: true)
#   * Lambda Proxy統合
# - aws_api_gateway_deployment
# - aws_api_gateway_stage: var.stage_name
# - aws_api_gateway_api_key: "ansible-ai-reviewer-key"
# - aws_api_gateway_usage_plan:
#   * スロットリング: rate=10, burst=20
#   * クォータ: 1000回/月
# - aws_api_gateway_usage_plan_key（API KeyとUsage Planの紐付け）
# - aws_lambda_permission (API GatewayからLambda呼び出し許可)
```

### terraform/modules/api_gateway/variables.tf
```
必要な変数定義
```

### terraform/modules/api_gateway/outputs.tf
```
- api_endpoint (例: https://xxxxx.execute-api.ap-northeast-1.amazonaws.com/v1/review)
- api_key_id
```

### terraform/main.tf
```hcl
以下を定義:

1. data "aws_caller_identity" "current" {}

2. IAMロール: ansible-ai-reviewer-role
   - Lambda信頼ポリシー
   - インラインポリシー:
     * bedrock:InvokeModel (us-east-1, Claude Sonnet 3.5のARNのみ)
     * ssm:GetParameter (/ansible-ai-reviewer/*)
     * logs:CreateLogGroup, logs:CreateLogStream, logs:PutLogEvents

3. SSMパラメータ (SecureString):
   - /ansible-ai-reviewer/github-token (値: "PLACEHOLDER")
   - /ansible-ai-reviewer/api-key-secret (値: "PLACEHOLDER", 追加の認証層として使用)

4. module "reviewer_lambda" の呼び出し

5. module "api_gateway" の呼び出し

6. aws_ssm_parameter でAPI Gateway API KeyのValueをSSMに保存
   (API Key作成後のValueをdata sourceで取得してSSMに格納)
```

### terraform/outputs.tf
```
- api_endpoint
- lambda_function_name
- reviewer_role_arn
```

### terraform/environments/dev/main.tf + terraform.tfvars
```
dev環境エントリーポイント
```

## 制約・注意事項

- IAMポリシーのResourceは最小化（Bedrockは特定モデルARNのみ）
- Bedrockモデル ARN: `arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-20250514-v1:0`
- API Gatewayのエンドポイントは `outputs.tf` でわかりやすく出力
- Terraformバージョン: `>= 1.9.0`, AWSプロバイダー: `~> 5.0`
- コメントは日本語で設計意図を記載
- 全リソースにCLAUDE.mdのタグ戦略を適用

## 完了確認

- [ ] `terraform fmt` エラーなし
- [ ] `terraform validate` エラーなし
- [ ] API GatewayにAPIキー認証が設定されていること
- [ ] SSMパラメータが SecureString であること
- [ ] IAMロールにワイルドカード`*`がないこと