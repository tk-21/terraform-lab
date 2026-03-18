# 運用ランブック

## はじめに

このランブックはインフラ運用者向けの手順書です。
日常運用・定期メンテナンス・スケールアップ・テナント管理の手順を記載します。

---

## 1. 日常運用

### 1-1. システム全体のヘルスチェック

```bash
# CloudWatch ダッシュボードを開く
# https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home#dashboards

# アラーム状態を一覧確認
aws cloudwatch describe-alarms \
  --alarm-name-prefix "bedrock-ai-platform-sandbox-dev" \
  --region ap-northeast-1 \
  --query "MetricAlarms[].{Name:AlarmName, State:StateValue}" \
  --output table
```

正常な状態: 全アラームが `OK` または `INSUFFICIENT_DATA`（データなし）

### 1-2. 月次コスト確認

```bash
# 当月のコスト概算（前日まで）
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --region us-east-1
```

月額 $30 が目安。超過しそうな場合は Aurora を停止して費用を抑える。

### 1-3. Lambda エラーログの確認

```bash
# Router Lambda のエラーログ（直近1時間）
aws logs filter-log-events \
  --log-group-name "/aws/lambda/bedrock-ai-platform-sandbox-dev-router" \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "ERROR" \
  --region ap-northeast-1

# Cost Controller のエラーログ
aws logs filter-log-events \
  --log-group-name "/aws/lambda/bedrock-ai-platform-sandbox-dev-cost-controller" \
  --start-time $(date -d '1 hour ago' +%s)000 \
  --filter-pattern "ERROR" \
  --region ap-northeast-1
```

---

## 2. Knowledge Base 管理

### 2-1. ドキュメントの追加・更新

```bash
# ドキュメントを S3 にアップロード
aws s3 cp <local_file> s3://<kb_documents_bucket>/<path>/

# ディレクトリごとアップロード
aws s3 sync ./docs/kb/ s3://<kb_documents_bucket>/ --delete

# アップロード済みファイルの確認
aws s3 ls s3://<kb_documents_bucket>/ --recursive
```

### 2-2. Knowledge Base の同期（インデックス再構築）

ドキュメントをアップロードしただけでは検索に反映されない。同期ジョブを実行する。

```bash
# Knowledge Base ID と Data Source ID を確認
KB_ID=$(aws bedrock-agent list-knowledge-bases \
  --region ap-northeast-1 \
  --query "knowledgeBaseSummaries[?name=='bedrock-ai-platform-sandbox-dev-kb'].knowledgeBaseId" \
  --output text)

DS_ID=$(aws bedrock-agent list-data-sources \
  --knowledge-base-id $KB_ID \
  --region ap-northeast-1 \
  --query "dataSourceSummaries[0].dataSourceId" \
  --output text)

# 同期ジョブ開始
JOB_ID=$(aws bedrock-agent start-ingestion-job \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID \
  --region ap-northeast-1 \
  --query "ingestionJob.ingestionJobId" \
  --output text)

echo "Ingestion Job ID: $JOB_ID"

# 完了まで待機（COMPLETE になるまでポーリング）
while true; do
  STATUS=$(aws bedrock-agent get-ingestion-job \
    --knowledge-base-id $KB_ID \
    --data-source-id $DS_ID \
    --ingestion-job-id $JOB_ID \
    --region ap-northeast-1 \
    --query "ingestionJob.status" \
    --output text)
  echo "Status: $STATUS"
  [ "$STATUS" = "COMPLETE" ] && break
  [ "$STATUS" = "FAILED" ] && echo "ERROR: Ingestion failed" && exit 1
  sleep 30
done
```

### 2-3. ドキュメントの削除

```bash
# S3 からファイルを削除
aws s3 rm s3://<kb_documents_bucket>/<path>/

# 削除後、同期ジョブを実行してインデックスを更新（2-2 参照）
```

### 2-4. 同期履歴の確認

```bash
aws bedrock-agent list-ingestion-jobs \
  --knowledge-base-id $KB_ID \
  --data-source-id $DS_ID \
  --region ap-northeast-1 \
  --query "ingestionJobSummaries[].{JobId:ingestionJobId,Status:status,Started:startedAt}" \
  --output table
```

---

## 3. テナント管理

### 3-1. 新規テナントの追加

```bash
TENANT_TABLE="bedrock-ai-platform-sandbox-dev-tenants"

aws dynamodb put-item \
  --table-name $TENANT_TABLE \
  --item '{
    "tenant_id":           {"S": "tenant-example"},
    "tier":                {"S": "standard"},
    "token_limit_daily":   {"N": "200000"},
    "token_limit_monthly": {"N": "4000000"},
    "guardrail_enabled":   {"BOOL": true},
    "created_at":          {"S": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}
  }' \
  --region ap-northeast-1
```

**Tier の選択基準**:

| Tier | 日次上限 | 推奨用途 |
|------|---------|---------|
| free | 10,000 トークン | 評価・テスト用途 |
| standard | 100,000 トークン | 通常業務 |
| premium | 500,000 トークン | ヘビーユーザー・Sonnet 固定が必要な場合 |

### 3-2. テナント設定の確認

```bash
# 特定テナントの設定を取得
aws dynamodb get-item \
  --table-name $TENANT_TABLE \
  --key '{"tenant_id": {"S": "tenant-example"}}' \
  --region ap-northeast-1

# 全テナント一覧
aws dynamodb scan \
  --table-name $TENANT_TABLE \
  --region ap-northeast-1 \
  --query "Items[].{ID:tenant_id.S, Tier:tier.S, DailyLimit:token_limit_daily.N}" \
  --output table
```

### 3-3. テナントのトークン使用量確認

```bash
USAGE_TABLE="bedrock-ai-platform-sandbox-dev-usage"
TODAY=$(date +%Y%m%d)

# 特定テナントの本日の使用量
aws dynamodb get-item \
  --table-name $USAGE_TABLE \
  --key '{"tenant_id": {"S": "default"}, "date": {"S": "'"$TODAY"'"}}' \
  --region ap-northeast-1

# 全テナントの本日の使用量
aws dynamodb scan \
  --table-name $USAGE_TABLE \
  --filter-expression "#d = :today" \
  --expression-attribute-names '{"#d": "date"}' \
  --expression-attribute-values '{":today": {"S": "'"$TODAY"'"}}' \
  --region ap-northeast-1 \
  --query "Items[].{TenantID:tenant_id.S, Total:total_tokens.N, Model:last_model.S}" \
  --output table
```

### 3-4. テナントのトークン上限変更

```bash
aws dynamodb update-item \
  --table-name $TENANT_TABLE \
  --key '{"tenant_id": {"S": "tenant-example"}}' \
  --update-expression "SET token_limit_daily = :limit" \
  --expression-attribute-values '{":limit": {"N": "300000"}}' \
  --region ap-northeast-1
```

### 3-5. テナントの削除

```bash
aws dynamodb delete-item \
  --table-name $TENANT_TABLE \
  --key '{"tenant_id": {"S": "tenant-example"}}' \
  --region ap-northeast-1
```

---

## 4. Aurora PostgreSQL 管理

### 4-1. Aurora の停止（コスト削減）

使用しない期間は Aurora を停止することで ACU 料金を節約できる。

```bash
CLUSTER_ID="bedrock-ai-platform-sandbox-dev-aurora"

aws rds stop-db-cluster \
  --db-cluster-identifier $CLUSTER_ID \
  --region ap-northeast-1

# 停止完了まで待機
aws rds wait db-cluster-stopped \
  --db-cluster-identifier $CLUSTER_ID \
  --region ap-northeast-1

echo "Aurora stopped."
```

> **注意**: AWS は停止状態の Aurora を **7日後に自動的に再起動**します。
> 長期間使用しない場合は `terraform destroy` で削除することを推奨します。

### 4-2. Aurora の再起動

```bash
aws rds start-db-cluster \
  --db-cluster-identifier $CLUSTER_ID \
  --region ap-northeast-1

aws rds wait db-cluster-available \
  --db-cluster-identifier $CLUSTER_ID \
  --region ap-northeast-1

echo "Aurora started."
```

### 4-3. Aurora への接続（デバッグ用）

RDS Data API 経由でクエリを実行する（セキュリティグループ・SSHトンネル不要）。

```bash
SECRET_ARN=$(aws secretsmanager list-secrets \
  --region ap-northeast-1 \
  --query "SecretList[?contains(Name, 'aurora')].ARN" \
  --output text)

CLUSTER_ARN=$(aws rds describe-db-clusters \
  --db-cluster-identifier $CLUSTER_ID \
  --region ap-northeast-1 \
  --query "DBClusters[0].DBClusterArn" \
  --output text)

# ベクトルデータの件数確認
aws rds-data execute-statement \
  --resource-arn $CLUSTER_ARN \
  --secret-arn $SECRET_ARN \
  --database "postgres" \
  --sql "SELECT COUNT(*) FROM bedrock_integration.bedrock_kb;" \
  --region ap-northeast-1
```

---

## 5. スケールアップ手順

### 5-1. Aurora の最大 ACU を変更する

デフォルトは 4.0 ACU。大量のベクトル検索が発生する場合は上限を引き上げる。

`modules/knowledge-base/main.tf` 内の `serverlessv2_scaling_configuration` を変更してから `terraform apply` を実行する。

```hcl
serverlessv2_scaling_configuration {
  min_capacity = 0.5
  max_capacity = 8.0  # 4.0 → 8.0 に変更（月額 +$15〜30 程度）
}
```

### 5-2. Lambda メモリの変更

処理時間が長い場合はメモリを増やすことで CPU も強化される。

`environments/dev/terraform.tfvars` に変数を追加（各モジュールの `lambda_memory_mb` 変数を利用）:

```hcl
# router_lambda_memory_mb = 512  # デフォルト: 512MB
```

### 5-3. API Gateway スロットリングの変更

`modules/api-gateway/variables.tf` のデフォルト値を変更するか、`environments/dev/main.tf` で上書きする:

```hcl
module "api_gateway" {
  throttle_burst_limit = 200  # デフォルト: 100
  throttle_rate_limit  = 100  # デフォルト: 50
}
```

---

## 6. Terraform 運用

### 6-1. 特定モジュールだけ再適用

```bash
# networking モジュールのみ再適用
terraform apply -target=module.networking -var="owner=your-name"

# Aurora クラスターのみ再適用
terraform apply -target=module.knowledge_base.aws_rds_cluster.main -var="owner=your-name"
```

### 6-2. state の確認

```bash
# 管理リソースの一覧
terraform state list

# 特定リソースの詳細
terraform state show module.networking.aws_vpc.main
```

### 6-3. ドリフト（手動変更）の検出

```bash
terraform plan -var="owner=your-name" -refresh-only
```

差分が出た場合は `terraform apply -refresh-only` で state を実態に合わせるか、原因を特定して手動変更を巻き戻す。

---

## 7. 定期メンテナンス

### 毎月実施

- [ ] AWS Cost Explorer で実費を確認（月初 5 日までに前月分が確定）
- [ ] CloudTrail ログの S3 バケット使用量確認
- [ ] DynamoDB usage テーブルの TTL 期限切れアイテムが削減されていることを確認
- [ ] Bedrock Guardrail の設定見直し（新しい脅威パターンの追加）

### 四半期ごとに実施

- [ ] Terraform / AWS Provider のバージョンアップ検討
- [ ] IAM ロール・ポリシーの棚卸し（不要な権限がないか確認）
- [ ] Aurora PostgreSQL のマイナーバージョンアップ検討
- [ ] Knowledge Base のドキュメント内容の見直し・更新
