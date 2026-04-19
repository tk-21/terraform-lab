# 運用手順書

---

## セットアップ

### 前提条件

| 項目 | 要件 |
|---|---|
| Terraform | >= 1.9 |
| AWS CLI | v2、プロファイル設定済み |
| GitHub CLI | `gh` コマンドが使用可能 |
| Amazon Bedrock | `us-east-1` で Claude Sonnet 3.5 が有効化済み |

### 1. GitHub Actions OIDC ロールの設定

TerraformデプロイにはAWS OIDCを使用する（アクセスキー不要）。

```bash
# GitHub OIDCプロバイダーをAWSに登録（初回のみ）
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1 \
  --region ap-northeast-1
```

Terraformが `iam_oidc_role` を作成するため、以下のように `terraform.tfvars` でリポジトリを指定する:

```hcl
github_repo = "your-org/ansible-playbook-ai-reviewer"
```

### 2. Terraformデプロイ

```bash
cd terraform/environments/dev
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集

terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

デプロイ後に表示される Output をメモする:

```
api_endpoint           = "https://xxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod"
api_key_ssm_param_name = "/ansible-ai-reviewer/api-key"
lambda_function_name   = "ansible-ai-reviewer"
```

### 3. SSMパラメータへのSecretsを設定

```bash
# GitHubトークンを設定（repo + pull_requests スコープが必要）
aws ssm put-parameter \
  --name "/ansible-ai-reviewer/github-token" \
  --value "ghp_xxxxxxxxxxxxxxxxxxxx" \
  --type SecureString \
  --region ap-northeast-1

# API追加認証シークレットを設定（ランダム文字列を生成して使用）
SECRET=$(openssl rand -hex 32)
echo "api_secret: $SECRET"  # この値をGitHub Secretsに設定する

aws ssm put-parameter \
  --name "/ansible-ai-reviewer/api-key-secret" \
  --value "$SECRET" \
  --type SecureString \
  --region ap-northeast-1
```

### 4. API GatewayキーをGitHub Secretsに設定

```bash
# API Gatewayキーの値を取得
KEY_ID=$(aws ssm get-parameter \
  --name "/ansible-ai-reviewer/api-key" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region ap-northeast-1)

API_KEY_VALUE=$(aws apigateway get-api-key \
  --api-key "$KEY_ID" \
  --include-value \
  --query "value" \
  --output text \
  --region ap-northeast-1)

echo "API Key: $API_KEY_VALUE"
```

レビュー対象リポジトリの `Settings → Secrets and variables → Actions` に追加:

| Secret名 | 値 |
|---|---|
| `AI_REVIEWER_API_ENDPOINT` | Terraformの `api_endpoint` output |
| `AI_REVIEWER_API_KEY` | 上記で取得した API Key の値 |
| `AI_REVIEWER_API_SECRET` | SSMに設定した `api-key-secret` の値 |

---

## 動作確認

### curl でAPIを手動呼び出し（疎通確認）

```bash
# 環境変数を設定
export API_ENDPOINT="https://xxxxxx.execute-api.ap-northeast-1.amazonaws.com/prod"
export API_KEY="your-api-key-value"
export API_SECRET="your-api-secret-value"

# ヘルスチェック（GETリクエスト）
curl -s -o /dev/null -w "%{http_code}" \
  -H "x-api-key: $API_KEY" \
  "$API_ENDPOINT/" 
# 期待値: 200 または 403（POSTのみ受け付けるなら403）

# sample_playbook_bad.yml でレビューAPIを呼び出す
curl -X POST "$API_ENDPOINT/review" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -d "{
    \"playbook_content\": \"$(base64 -w 0 examples/sample_playbook_bad.yml)\",
    \"playbook_filename\": \"sample_playbook_bad.yml\",
    \"github_repo_owner\": \"your-org\",
    \"github_repo_name\": \"your-repo\",
    \"pr_number\": 1,
    \"api_secret\": \"$API_SECRET\"
  }" | jq .
```

期待されるレスポンス:
```json
{
  "status": "success",
  "overall_score": 30,
  "risk_level": "CRITICAL",
  "issues_count": 9,
  "comment_url": "https://github.com/your-org/your-repo/pull/1#issuecomment-...",
  "message": "レビュー完了: 9件の問題を検出しました（スコア: 30/100）"
}
```

### sample_playbook_bad.yml を使ったEnd-to-Endテスト手順

1. テスト用リポジトリを作成（または既存リポジトリのPRを使用）
2. `examples/sample_playbook_bad.yml` を含むブランチを作成してPRを開く
3. `.github/workflows/example_ansible_review.yml` がトリガーされることを確認
4. GitHub Actions ログでレビュー処理が完了することを確認
5. PRコメントにMarkdownレビュー結果が投稿されることを確認
6. `ai-review: critical` と `do-not-merge` ラベルが付与されることを確認
7. GitHub Actions が exit 1 でfailしていることを確認（`fail_on_critical: 'true'` の場合）

---

## トラブルシューティング

### Lambda タイムアウト（Bedrock呼び出し遅延）

**症状**: Lambda がタイムアウトエラーを返す。CloudWatch Logsに `Task timed out` が記録される。

**原因**: Bedrock のレスポンスに時間がかかっている（Claude Sonnet 3.5は大きなPlaybookで20-40秒かかることがある）

**対処**:
```bash
# Lambda タイムアウトを延長（Terraform変数で設定）
# terraform.tfvars に追記:
lambda_timeout = 120   # デフォルト60秒 → 120秒に延長

terraform apply
```

### API Key認証エラー（HTTP 403）

**症状**: `curl` から `{"message":"Forbidden"}` が返る

**確認手順**:
```bash
# APIキーの有効性を確認
aws apigateway get-api-keys \
  --include-values \
  --region ap-northeast-1 \
  --query "items[?name=='ansible-ai-reviewer-key'].{id:id, enabled:enabled, value:value}"

# 使用量プランにAPIキーが紐付いているか確認
PLAN_ID=$(aws apigateway get-usage-plans \
  --region ap-northeast-1 \
  --query "items[?name=='ansible-ai-reviewer-plan'].id" \
  --output text)

aws apigateway get-usage-plan-keys \
  --usage-plan-id "$PLAN_ID" \
  --region ap-northeast-1
```

### GitHubトークン権限エラー

**症状**: Lambda の CloudWatch Logs に `403` または `Resource not accessible by integration` エラー

**確認手順**:
```bash
# SSMからトークンを取得して権限確認
TOKEN=$(aws ssm get-parameter \
  --name "/ansible-ai-reviewer/github-token" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region ap-northeast-1)

# トークンのスコープを確認
curl -s -H "Authorization: token $TOKEN" \
  https://api.github.com/repos/your-org/your-repo/pulls/1/comments \
  -o /dev/null -w "%{http_code}"
# 期待値: 200
```

**対処**: GitHubトークンに `repo` スコープと `pull_requests: write` 権限が必要。GitHub → Settings → Personal access tokens から再生成して SSM を更新する。

### api_secret認証エラー（HTTP 403 from Lambda）

**症状**: API Gateway は通過するが Lambda が `{"status":"error","error":"認証に失敗しました"}` を返す

**対処**:
```bash
# SSMのapi-key-secretを確認（GitHub Secretsと一致しているか）
aws ssm get-parameter \
  --name "/ansible-ai-reviewer/api-key-secret" \
  --with-decryption \
  --query "Parameter.Value" \
  --output text \
  --region ap-northeast-1
```

GitHub Secretsの `AI_REVIEWER_API_SECRET` と値が一致しているか確認する。不一致の場合はSSMを更新するか、GitHub Secretsを更新する。

### Bedrockのレート制限

**症状**: `ThrottlingException` がCloudWatch Logsに記録される

**対処**: Bedrock のサービスクォータを申請してレート制限を引き上げる。
または Lambda のコンカレンシーを制限してBedrockへのリクエスト頻度を下げる:

```hcl
# Terraform: Lambda の予約済みコンカレンシーを設定
resource "aws_lambda_function_event_invoke_config" "reviewer" {
  function_name = aws_lambda_function.reviewer.function_name
  maximum_retry_attempts = 0
}
```

---

## CloudWatch Logs Insights クエリ集

CloudWatch Logs Insights で以下のクエリを使用して運用状況を把握する。
ロググループ: `/aws/lambda/ansible-ai-reviewer`

### エラー率確認クエリ

```
fields @timestamp, level, message, error
| filter level = "ERROR"
| sort @timestamp desc
| limit 50
```

### 処理時間分布クエリ

```
filter @type = "REPORT"
| stats
    avg(@duration) as avg_ms,
    max(@duration) as max_ms,
    min(@duration) as min_ms,
    percentile(@duration, 95) as p95_ms
  by bin(1h)
```

### CRITICALレビュー件数クエリ

```
fields @timestamp, risk_level, score, issues_count, filename
| filter ispresent(risk_level)
| filter risk_level = "CRITICAL"
| sort @timestamp desc
| limit 100
```

### 直近24時間のレビュー成功/失敗集計

```
fields @timestamp, status
| filter ispresent(status)
| stats count(*) as total by status
| sort total desc
```

### Bedrock呼び出し失敗の調査

```
fields @timestamp, message, error
| filter message like "Bedrockレビュー失敗"
| sort @timestamp desc
| limit 20
```

---

## メンテナンス

### GitHubトークンの更新手順

GitHubトークンは有効期限（通常90日）があるため、定期更新が必要。

```bash
# 1. GitHubで新しいPATを生成（repo + pull_requests スコープ）
# https://github.com/settings/tokens

# 2. SSMパラメータを上書き更新
aws ssm put-parameter \
  --name "/ansible-ai-reviewer/github-token" \
  --value "ghp_new_token_value" \
  --type SecureString \
  --overwrite \
  --region ap-northeast-1

# 3. 動作確認（curl で手動テスト）
```

### Bedrockモデルのアップデート方法

`bedrock_reviewer.py` の `model_id` を変更してLambdaを再デプロイする:

```python
# bedrock_reviewer.py の定数を変更
MODEL_ID = "us.anthropic.claude-sonnet-4-7-20251115-v1:0"  # 新モデルに変更
```

```bash
# Lambda関数を再デプロイ
cd terraform/environments/dev
terraform apply -target=module.reviewer_lambda
```

### 月次コスト確認

```bash
# AWS Cost Explorerでansible-ai-reviewerのコストを確認
aws ce get-cost-and-usage \
  --time-period Start=2026-04-01,End=2026-04-30 \
  --granularity MONTHLY \
  --filter '{"Tags":{"Key":"Project","Values":["ansible-playbook-ai-reviewer"]}}' \
  --metrics BlendedCost \
  --query "ResultsByTime[0].Total.BlendedCost"
```
