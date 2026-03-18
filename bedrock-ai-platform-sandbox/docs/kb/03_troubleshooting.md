# トラブルシューティングガイド

## 症状別インデックス

| 症状 | 参照セクション |
|-----|-------------|
| API が 429 を返す | 1-1 |
| API が 500 を返す | 1-2 |
| API が 403 を返す（WAF ブロック） | 1-3 |
| Bedrock の呼び出しが失敗する | 2-1 |
| Bedrock の応答が遅い | 2-2 |
| Guardrail でリクエストがブロックされる | 2-3 |
| Knowledge Base の検索精度が低い | 3-1 |
| Knowledge Base の同期が失敗する | 3-2 |
| Aurora に接続できない | 4-1 |
| Aurora の起動が遅い | 4-2 |
| Lambda がタイムアウトする | 5-1 |
| Lambda が VPC 内で Bedrock に接続できない | 5-2 |
| DynamoDB のテナントが見つからない | 6-1 |
| コストが予算を超えている | 7-1 |
| GitHub Actions の plan が失敗する | 8-1 |
| GitHub Actions の apply が失敗する | 8-2 |

---

## 1. API Gateway / エンドポイント

### 1-1. 429 Too Many Requests が返る

**考えられる原因**:
- テナントのトークン使用量が日次上限に達している
- WAF の IP レートリミットに引っかかっている
- API Gateway のスロットリング上限に達している

**診断手順**:

```bash
# テナントの使用量確認
TODAY=$(date +%Y%m%d)
aws dynamodb get-item \
  --table-name bedrock-ai-platform-sandbox-dev-usage \
  --key '{"tenant_id": {"S": "default"}, "date": {"S": "'"$TODAY"'"}}' \
  --region ap-northeast-1

# WAF ログ確認（ブロックされたリクエスト）
aws wafv2 get-sampled-requests \
  --web-acl-arn <WAF_ARN> \
  --rule-metric-name bedrock-ai-platform-sandbox-dev-waf-rate-limit \
  --scope REGIONAL \
  --time-window Start=$(date -d '1 hour ago' -u +%s),End=$(date -u +%s) \
  --max-items 10 \
  --region ap-northeast-1
```

**対処**:
- トークン上限起因: テナントの `token_limit_daily` を引き上げる（ランブック 3-4 参照）
- WAF 起因: 正当なトラフィックであれば `waf_rate_limit` 変数を引き上げて `terraform apply`
- スロットリング起因: `throttle_burst_limit` / `throttle_rate_limit` を引き上げて `terraform apply`

### 1-2. 500 Internal Server Error が返る

**考えられる原因**:
- Router Lambda の実行エラー
- Bedrock API の障害
- DynamoDB の接続エラー

**診断手順**:

```bash
# Router Lambda の最新エラーログを確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/bedrock-ai-platform-sandbox-dev-router" \
  --start-time $(date -d '30 minutes ago' +%s)000 \
  --filter-pattern "ERROR" \
  --region ap-northeast-1 \
  --query "events[].message" \
  --output text

# X-Ray でトレースを確認
aws xray get-trace-summaries \
  --start-time $(date -d '30 minutes ago' -u +%s) \
  --end-time $(date -u +%s) \
  --filter-expression "fault = true" \
  --region ap-northeast-1
```

**対処**:
- Lambda エラー: ログの stack trace を確認して原因を特定
- Bedrock 障害: [AWS Health Dashboard](https://health.aws.amazon.com/) を確認
- DynamoDB エラー: VPC Endpoint の設定を確認

### 1-3. 403 Forbidden が返る（WAF ブロック）

**考えられる原因**:
- WAF の AWSManagedRulesCommonRuleSet にマッチした
- 既知の悪意あるパターン（SQLi / XSS 等）が含まれていた

**診断手順**:

```bash
# API Gateway アクセスログで詳細確認
aws logs filter-log-events \
  --log-group-name "/aws/apigateway/bedrock-ai-platform-sandbox-dev" \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --region ap-northeast-1
```

**対処**:
- プロンプト内の特殊文字を URL エンコードして再試行
- 正当なリクエストがブロックされる場合は WAF ルールを `COUNT` モードに変更して調査

---

## 2. Bedrock

### 2-1. Bedrock の呼び出しが失敗する（AccessDeniedException）

**考えられる原因**:
- IAM ロールに指定モデルの呼び出し権限がない
- モデルがリージョンで有効化されていない
- VPC Endpoint 経由での接続ができていない

**診断手順**:

```bash
# IAM ポリシーで許可しているモデル ARN を確認
aws iam get-policy-version \
  --policy-arn <BEDROCK_IAM_POLICY_ARN> \
  --version-id v1 \
  --region ap-northeast-1

# Bedrock で有効化されているモデルを確認
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --query "modelSummaries[?modelLifecycle.status=='ACTIVE'].{ID:modelId}" \
  --output table

# VPC Endpoint の状態確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.bedrock-runtime" \
  --region ap-northeast-1 \
  --query "VpcEndpoints[].State"
```

**対処**:
1. AWS コンソール → Amazon Bedrock → モデルアクセス → 対象モデルを有効化
2. VPC Endpoint が `available` でない場合は `terraform apply` で再作成

### 2-2. Bedrock の応答が遅い（レイテンシ高）

**目安**:
- Haiku: 通常 1〜3 秒
- Sonnet: 通常 3〜10 秒
- これを大幅に超える場合は調査が必要

**診断手順**:

```bash
# CloudWatch ダッシュボードで Router Lambda の Duration p99 を確認
# X-Ray トレースで Bedrock 呼び出し時間を特定
aws xray get-trace-summaries \
  --start-time $(date -d '1 hour ago' -u +%s) \
  --end-time $(date -u +%s) \
  --region ap-northeast-1 \
  --query "TraceSummaries[?ResponseTime > \`5.0\`].{ID:Id, Duration:ResponseTime}" \
  --output table
```

**対処**:
- Aurora が停止または ACU がスケールアップ中の場合、RAG 検索のレイテンシが増大する。Aurora の状態を確認してウォームアップを待つ。
- Lambda のコールドスタートが原因の場合、Provisioned Concurrency の設定を検討（コスト増加に注意）

### 2-3. Guardrail でリクエストがブロックされる

**症状**: 応答が "このリクエストには応答できません" 等のブロックメッセージになる

**診断手順**:

```bash
# CloudTrail で Guardrail の ApplyGuardrail イベントを確認
aws logs filter-log-events \
  --log-group-name <CLOUDTRAIL_LOG_GROUP> \
  --filter-pattern '{ $.eventName = "ApplyGuardrail" }' \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --region ap-northeast-1
```

**対処**:
- PII（メールアドレス・電話番号等）が含まれているとブロックされる仕様。プロンプトから個人情報を除いて再試行。
- プロンプトインジェクション疑いでブロックされている場合は、リクエスト内容を見直す。
- 正当なコンテンツがブロックされる場合は Guardrail の閾値を `bedrock-foundation` モジュールで調整して `terraform apply`。

---

## 3. Knowledge Base

### 3-1. Knowledge Base の検索精度が低い

**原因と対策**:

| 原因 | 対策 |
|-----|-----|
| ドキュメントが古い・同期されていない | ingestion job を再実行（ランブック 2-2 参照） |
| チャンクサイズが不適切 | `modules/knowledge-base/main.tf` の `chunking_configuration` を調整（デフォルト: 512 トークン、オーバーラップ 10%） |
| ドキュメントの質が低い | 見出し・箇条書き・表などで構造化された Markdown を使用する |
| ベクトルインデックスが破損している | Aurora の bedrock_kb テーブルを DROP して再同期 |

**チャンクサイズの目安**:
- 技術仕様書（詳細が必要）: 256〜512 トークン
- FAQ・Q&A 形式: 128〜256 トークン
- 長い論文・設計書: 512〜1024 トークン

### 3-2. Knowledge Base の同期が FAILED になる

**診断手順**:

```bash
# 失敗した ingestion job の詳細を確認
aws bedrock-agent get-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID \
  --ingestion-job-id $JOB_ID \
  --region ap-northeast-1 \
  --query "ingestionJob.{Status:status, FailureReasons:failureReasons}"
```

**よくある失敗原因**:
- Aurora が停止中: Aurora を起動してから再試行（ランブック 4-2 参照）
- Secrets Manager へのアクセス権限不足: IAM ロールの `bedrock_kb` ポリシーを確認
- S3 バケットのアクセス権限不足: バケットポリシーと IAM ポリシーを確認
- ドキュメントのサイズが 50MB を超えている: ファイルを分割する

---

## 4. Aurora PostgreSQL

### 4-1. Aurora に接続できない / RDS Data API がエラーを返す

**診断手順**:

```bash
CLUSTER_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier bedrock-ai-platform-sandbox-dev-aurora \
  --region ap-northeast-1 \
  --query "DBClusters[0].DBClusterArn" \
  --output text)

# クラスターの状態確認
aws rds describe-db-clusters \
  --db-cluster-identifier bedrock-ai-platform-sandbox-dev-aurora \
  --region ap-northeast-1 \
  --query "DBClusters[0].{Status:Status, Engine:Engine, EngineVersion:EngineVersion}"
```

**状態別の対処**:

| Status | 意味 | 対処 |
|-------|------|-----|
| available | 正常 | 接続情報を再確認 |
| stopped | 停止中 | `aws rds start-db-cluster` で起動 |
| starting | 起動中 | 数分待つ |
| modifying | 変更適用中 | 完了まで待つ |
| backing-up | バックアップ中 | 完了まで待つ（通常 5 分以内） |
| failing-over | フェイルオーバー中 | 完了まで待つ |

### 4-2. Aurora の起動が遅い / ACU スケールアップ中

Serverless v2 は 0 ACU から起動する際に **コールドスタート（10〜60秒）** が発生する。

**対策**:
- 使用前に軽いクエリを投げて ウォームアップする
- `min_capacity` を `0.5` より大きい値（例: `1.0`）にする（コスト増加に注意）
- Aurora を停止せずに常時起動しておく

---

## 5. Lambda

### 5-1. Lambda がタイムアウトする（30秒制限）

**診断手順**:

```bash
# タイムアウト発生の確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Duration \
  --dimensions Name=FunctionName,Value=bedrock-ai-platform-sandbox-dev-router \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Maximum \
  --region ap-northeast-1
```

**対処**:
- Bedrock の応答時間が原因: Lambda の `timeout` を 60 秒に引き上げる（`main.tf` を修正して `terraform apply`）
- Aurora のコールドスタートが原因: Aurora ウォームアップの対策を実施

### 5-2. Lambda が VPC 内で Bedrock に接続できない

**症状**: `Connect timeout` / `Connection refused` エラー

**診断手順**:

```bash
# VPC Endpoint の状態確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.ap-northeast-1.bedrock-runtime" \
  --region ap-northeast-1 \
  --query "VpcEndpoints[].{State:State, SubnetIds:SubnetIds}"

# セキュリティグループの設定確認（VPC Endpoint SG が 443 を許可しているか）
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=bedrock-ai-platform-sandbox-dev-vpc-endpoints" \
  --region ap-northeast-1 \
  --query "SecurityGroups[].IpPermissions"
```

**対処**:
- VPC Endpoint が `pending` の場合: 数分待つか `terraform apply` で再作成
- セキュリティグループが VPC CIDR からの 443 を許可していない: `modules/networking/main.tf` を確認して `terraform apply`
- プライベート DNS が無効になっている: VPC Endpoint の `private_dns_enabled = true` を確認

---

## 6. DynamoDB

### 6-1. テナントが見つからない（404 エラー）

**症状**: router-lambda が `tenant not found` を返す

**対処**:

```bash
# テナントが登録されているか確認
aws dynamodb get-item \
  --table-name bedrock-ai-platform-sandbox-dev-tenants \
  --key '{"tenant_id": {"S": "default"}}' \
  --region ap-northeast-1

# 未登録の場合は登録する
aws dynamodb put-item \
  --table-name bedrock-ai-platform-sandbox-dev-tenants \
  --item '{
    "tenant_id":           {"S": "default"},
    "tier":                {"S": "standard"},
    "token_limit_daily":   {"N": "100000"},
    "token_limit_monthly": {"N": "2000000"},
    "guardrail_enabled":   {"BOOL": true},
    "created_at":          {"S": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}
  }' \
  --region ap-northeast-1
```

---

## 7. コスト

### 7-1. コストが月額 $30 を超えそう

**コスト削減の優先順位**:

1. **Aurora を停止する**（削減効果: $2〜5/月）
   ```bash
   aws rds stop-db-cluster \
     --db-cluster-identifier bedrock-ai-platform-sandbox-dev-aurora \
     --region ap-northeast-1
   ```

2. **Interface VPC Endpoint を削除する**（削減効果: ~$14/月、Bedrock へのアクセス不可になるため注意）
   - `modules/networking/main.tf` から bedrock-runtime・secretsmanager の VPC Endpoint を削除
   - Lambda を VPC 外に移動させる必要あり

3. **WAF を無効化する**（削減効果: ~$8/月、セキュリティリスクに注意）
   - `modules/api-gateway/main.tf` から WAF 関連リソースを削除

4. **使用頻度を下げる**（モデル呼び出し費用を削減）
   - Sonnet の代わりに Haiku を使うようにルーティング閾値を調整

---

## 8. GitHub Actions CI/CD

### 8-1. Terraform Plan が失敗する

**よくある原因**:

| エラーメッセージ | 原因 | 対処 |
|--------------|------|-----|
| `Error: configuring Terraform AWS Provider` | OIDC ロールの ARN が間違っている | `AWS_ROLE_ARN` シークレットを確認 |
| `Error: Failed to get existing workspaces` | S3 バケット・DynamoDB テーブルが存在しない | バックエンドリソースを手動作成（README のクイックスタート参照） |
| `Error: Invalid function argument` | 変数の型不一致 | `terraform validate` をローカルで確認 |
| `Error: Unsupported argument` | Provider バージョン不一致 | `TF_VERSION` を最新に更新 |

### 8-2. Terraform Apply が失敗する

**対処**:

```bash
# ローカルで state を確認して中途半端なリソースを特定
terraform state list

# 失敗したリソースのみ再適用
terraform apply -target=<resource_address> -var="owner=your-name"
```

**apply が途中で止まった場合の注意**:
- state ファイルはロックされている可能性がある。DynamoDB の LockID レコードを確認して手動解除する。
  ```bash
  aws dynamodb scan \
    --table-name tfstate-lock-bedrock-ai-platform \
    --region ap-northeast-1
  # LockID が残っている場合は delete-item で削除
  ```
