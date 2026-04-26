# 運用手順書

## 日常運用

### ログ確認方法

#### 直近の実行ログをまとめて確認（CloudWatch Logs Insights）

AWSコンソール → CloudWatch → Logs Insights で以下のクエリを実行します。

**drift-detector: エラーのみ抽出**
```
fields @timestamp, @message, level, error
| filter @logGroup = "/aws/lambda/drift-detective-drift-detector"
| filter level = "ERROR" or ispresent(error)
| sort @timestamp desc
| limit 50
```

**bedrock-analyzer: バリデーションエラー確認**
```
fields @timestamp, @message, validation_errors
| filter @logGroup = "/aws/lambda/drift-detective-bedrock-analyzer"
| filter @message like /validation/
| sort @timestamp desc
| limit 20
```

**pr-creator: PR作成成功ログ確認**
```
fields @timestamp, pr_url, severity, affected_count
| filter @logGroup = "/aws/lambda/drift-detective-pr-creator"
| filter @message like /PR created/
| sort @timestamp desc
| limit 30
```

**全Lambdaの実行時間とコスト確認**
```
fields @timestamp, @logStream, @duration, @billedDuration, @memorySize, @maxMemoryUsed
| filter @type = "REPORT"
| filter @logGroup in [
    "/aws/lambda/drift-detective-drift-detector",
    "/aws/lambda/drift-detective-bedrock-analyzer",
    "/aws/lambda/drift-detective-pr-creator"
  ]
| stats avg(@duration), max(@duration), sum(@billedDuration) by @logGroup
```

### Step Functions 実行履歴確認

```bash
# 直近10件の実行履歴を確認
aws stepfunctions list-executions \
  --state-machine-arn "arn:aws:states:ap-northeast-1:$(aws sts get-caller-identity --query Account --output text):stateMachine:DriftDetectionWorkflow" \
  --max-results 10 \
  --region ap-northeast-1

# 特定実行の詳細（FAILED時の原因確認）
aws stepfunctions describe-execution \
  --execution-arn "arn:aws:states:ap-northeast-1:ACCOUNT_ID:execution:DriftDetectionWorkflow:EXECUTION_ID" \
  --region ap-northeast-1

# 実行履歴のイベント（ステート遷移ログ）
aws stepfunctions get-execution-history \
  --execution-arn "arn:aws:states:ap-northeast-1:ACCOUNT_ID:execution:DriftDetectionWorkflow:EXECUTION_ID" \
  --region ap-northeast-1
```

### 手動で実行をトリガーする

```bash
# Step Functions を手動起動
aws stepfunctions start-execution \
  --state-machine-arn "arn:aws:states:ap-northeast-1:$(aws sts get-caller-identity --query Account --output text):stateMachine:DriftDetectionWorkflow" \
  --region ap-northeast-1

# 実行状態をポーリングで確認
EXEC_ARN=$(aws stepfunctions list-executions \
  --state-machine-arn "arn:aws:states:ap-northeast-1:$(aws sts get-caller-identity --query Account --output text):stateMachine:DriftDetectionWorkflow" \
  --max-results 1 \
  --query "executions[0].executionArn" \
  --output text \
  --region ap-northeast-1)

aws stepfunctions describe-execution --execution-arn "$EXEC_ARN" --region ap-northeast-1
```

---

## 障害対応

### drift-detector が失敗する場合

**症状:** Step FunctionsのDetectDriftステートがTaskFailedになる。

**確認手順:**

```bash
# 1. Lambdaのエラーログを確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/drift-detective-drift-detector" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern "ERROR" \
  --region ap-northeast-1

# 2. CloudFormation Drift Detectionのスタック状態を確認
aws cloudformation list-stacks \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --region ap-northeast-1
```

**よくある原因と対処:**

| 原因 | 確認方法 | 対処 |
|---|---|---|
| tfstateバケットへのアクセス権限不足 | LambdaロールのIAMポリシーを確認 | S3バケットポリシーまたはLambdaロールを修正 |
| tfstatバケット名またはキーが誤り | SSMパラメータ `/drift-detective/tfstate-bucket` を確認 | terraform.tfvarsを修正してapply |
| CloudFormation Drift Detection APIタイムアウト | スタックのリソース数が多すぎないか確認 | Lambdaタイムアウトを延長（最大15分） |
| monitored_tfstate_bucket が存在しない | S3バケット一覧で確認 | バケット名を正しく設定 |

---

### bedrock-analyzer がバリデーションエラーになる場合

**症状:** Step FunctionsのAnalyzeDriftステートがValidationFailedになる。

**確認手順:**

```bash
# バリデーションエラーの詳細を確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/drift-detective-bedrock-analyzer" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern "validation" \
  --region ap-northeast-1
```

**よくある原因と対処:**

| 原因 | 確認方法 | 対処 |
|---|---|---|
| Bedrockがフィールドを省略して返した | ログの `raw_response` を確認 | プロンプト（prompt_builder.py）を強化する |
| `severity` が想定外の値 | ログの `severity_value` を確認 | prompt_builder.pyのseverity指示を明確化 |
| `remediation_hcl` に `resource` キーワードなし | ログのhclフィールドを確認 | promptでHCL形式を明示する |
| Bedrockモデルへのアクセス権限不足 | IAMポリシーのbedrock:InvokeModelを確認 | LambdaロールにBedrockモデルARNを追加 |

**手動でBedrockをテスト:**

```bash
# Bedrockのモデルが呼び出せるか確認
aws bedrock-runtime invoke-model \
  --model-id anthropic.claude-sonnet-4-20250514-v1:0 \
  --body '{"anthropic_version":"bedrock-2023-05-31","max_tokens":100,"messages":[{"role":"user","content":"hello"}]}' \
  --region us-east-1 \
  /tmp/bedrock_test.json && cat /tmp/bedrock_test.json
```

---

### GitHub PR 作成が失敗する場合

**症状:** Step FunctionsのCreatePRステートがTaskFailedになる。

**確認手順:**

```bash
# pr-creator のエラーログを確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/drift-detective-pr-creator" \
  --start-time $(date -d '1 hour ago' +%s000) \
  --filter-pattern "ERROR" \
  --region ap-northeast-1
```

**よくある原因と対処:**

| 原因 | 確認方法 | 対処 |
|---|---|---|
| GitHub Token 期限切れ | ログの `401 Unauthorized` を確認 | SSMパラメータのトークンを更新（手順は下記） |
| GitHub Token の権限不足 | GitHub → Settings → Tokens でスコープ確認 | `repo` スコープを付与したTokenを再生成 |
| ブランチが既に存在する | GitHubのブランチ一覧を確認 | 古い修復ブランチを削除またはマージ |
| リポジトリ名・オーナー設定ミス | SSMパラメータ `/drift-detective/github-repo` を確認 | terraform.tfvarsを修正してapply |

---

## メンテナンス

### SSMパラメータ（トークン）の更新方法

#### GitHub Token の更新

1. GitHub → Settings → Developer settings → Personal access tokens → Generate new token
2. スコープ: `repo`（リポジトリへの読み書き権限）を選択
3. SSMに保存:

```bash
aws ssm put-parameter \
  --name "/drift-detective/github-token" \
  --value "ghp_新しいトークン" \
  --type SecureString \
  --overwrite \
  --region ap-northeast-1
```

#### Chatwork Token の更新

```bash
aws ssm put-parameter \
  --name "/drift-detective/chatwork-token" \
  --value "新しいChatworkトークン" \
  --type SecureString \
  --overwrite \
  --region ap-northeast-1
```

更新後、Lambdaは次回実行時に自動的に新しいトークンを取得します（再デプロイ不要）。

---

### Bedrockモデルのアップデート方法

新しいClaudeモデルに切り替える場合:

1. `terraform/modules/bedrock_analyzer/variables.tf` の `bedrock_model_id` のデフォルト値を変更

```hcl
variable "bedrock_model_id" {
  default = "anthropic.claude-sonnet-4-20250514-v1:0"  # ここを新モデルIDに変更
}
```

2. us-east-1でモデルが利用可能か確認:

```bash
aws bedrock list-foundation-models \
  --by-provider Anthropic \
  --region us-east-1 \
  --query "modelSummaries[].modelId"
```

3. Terraform apply:

```bash
cd terraform/environments/dev
terraform plan
terraform apply
```

---

### Lambda依存ライブラリの更新方法

```bash
# ローカルで依存関係を確認・更新
pip-audit -r lambda/drift_detector/requirements.txt
pip-audit -r lambda/bedrock_analyzer/requirements.txt
pip-audit -r lambda/pr_creator/requirements.txt

# requirements.txtのバージョンを更新後、GitHubにpush
# → lambda_deploy.yml が自動でデプロイ
git add lambda/*/requirements.txt
git commit -m "chore: update Lambda dependencies"
git push origin main
```

---

## コスト管理

### 月次コスト確認方法

```bash
# 当月のLambdaコストを確認（Cost Explorerが有効な場合）
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --filter '{"Tags":{"Key":"Project","Values":["iac-drift-detective"]}}' \
  --metrics "BlendedCost" \
  --region us-east-1

# CloudWatchでLambda呼び出し回数を確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Invocations \
  --dimensions Name=FunctionName,Value=drift-detective-drift-detector \
  --start-time $(date -d '30 days ago' --iso-8601)T00:00:00Z \
  --end-time $(date --iso-8601)T00:00:00Z \
  --period 2592000 \
  --statistics Sum \
  --region ap-northeast-1
```

### コスト削減オプション

| オプション | 変更箇所 | 削減効果 |
|---|---|---|
| 実行頻度を週1回に変更 | EventBridgeルールの`cron(0 0 ? * MON *)`に変更 | Bedrockコスト最大85%削減 |
| ドリフトなし時のBedrock呼び出しをスキップ（現状の設計通り） | Step Functionsの条件分岐で制御済み | 無駄なBedrock呼び出しなし |
| Lambda メモリサイズの最適化 | 各モジュールの`memory_size`変数を調整 | Lambda実行コスト削減 |
| S3レポートのライフサイクル設定 | S3バケットのライフサイクルルールを追加 | ストレージコスト削減 |
