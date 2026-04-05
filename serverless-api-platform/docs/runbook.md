# Runbook — serverless-api-platform

障害対応手順書。インシデント発生時はこのドキュメントに従い初動対応を行う。

---

## 目次

1. [5xx エラー急増の調査手順](#1-5xx-エラー急増の調査手順)
2. [DynamoDB CapacityUnits 超過](#2-dynamodb-capacityunits-超過)
3. [Lambda スロットリング](#3-lambda-スロットリング)
4. [Cognito 認証エラー急増](#4-cognito-認証エラー急増)
5. [CloudWatch アラーム一覧](#5-cloudwatch-アラーム一覧)

---

## 1. 5xx エラー急増の調査手順

### 症状

- CloudWatch アラーム `sap-dev-api-5xx-rate` が ALARM 状態
- API Gateway のメトリクス `5XXError` が急上昇
- エンドユーザーから「エラーが返る」という報告

### 調査ステップ

#### Step 1: API Gateway のエラー率を確認

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApiGateway \
  --metric-name 5XXError \
  --dimensions Name=ApiName,Value=sap-dev-api \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum \
  --output table
```

#### Step 2: CloudWatch Logs Insights でエラーを特定

```
# Lambda の構造化ログからエラー件数をカウント
fields @timestamp, level, message, function_name, statusCode
| filter level = "ERROR"
| stats count(*) as error_count by function_name, message
| sort error_count desc
| limit 20
```

実行方法:

```bash
aws logs start-query \
  --log-group-name /aws/lambda/sap-dev \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, level, message, function_name | filter level = "ERROR" | stats count(*) as error_count by function_name, message | sort error_count desc | limit 20'
```

#### Step 3: 特定の request_id でトレースを追跡

エラーレスポンスに含まれる `request_id` を使って詳細を追跡する:

```
# 特定の request_id に紐づくすべてのログを取得
fields @timestamp, level, message, error
| filter correlation_id = "<ERROR_RESPONSE_の_request_id>"
| sort @timestamp asc
```

#### Step 4: X-Ray トレースで瓶頸を特定

```bash
# X-Ray でエラーのあるトレースを取得
aws xray get-trace-summaries \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --filter-expression 'fault = true AND service(id(name: "sap-dev-*"))' \
  --output json | jq '.TraceSummaries[].Id'
```

### 原因別対処法

| 原因 | 症状 | 対処 |
|---|---|---|
| Lambda タイムアウト | `Task timed out after 25 seconds` | DynamoDB クエリのスロー原因を調査（GSI の Hot Partition など） |
| DynamoDB エラー | `ProvisionedThroughputExceededException` | → [DynamoDB 超過手順](#2-dynamodb-capacityunits-超過) |
| Lambda OOM | `Runtime exited with error: signal: killed` | Lambda のメモリ設定を増やす（terraform variables を更新） |
| デプロイ直後 | コールドスタート多発 | 数分待つ。Provisioned Concurrency の検討 |
| コード不具合 | `Unhandled exception` | エラー内容を確認してコード修正・再デプロイ |

---

## 2. DynamoDB CapacityUnits 超過

### 症状

- CloudWatch アラーム `sap-dev-dynamodb-throttle` が ALARM
- Lambda ログに `ProvisionedThroughputExceededException` または `RequestThrottled`
- `ConsumedReadCapacityUnits` / `ConsumedWriteCapacityUnits` が急増

### 調査ステップ

#### Step 1: 消費 CapacityUnits を確認

```bash
# 過去1時間の読み取り消費量
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ConsumedReadCapacityUnits \
  --dimensions Name=TableName,Value=sap-dev-items \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum \
  --output table
```

#### Step 2: スロットルされたリクエスト数を確認

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ThrottledRequests \
  --dimensions Name=TableName,Value=sap-dev-items \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum \
  --output table
```

#### Step 3: どの Lambda が高負荷か特定

```
# CloudWatch Logs Insights: DynamoDB 操作ごとのレイテンシ
fields @timestamp, function_name, message
| filter ispresent(dynamodb_operation)
| stats avg(duration_ms) as avg_ms, max(duration_ms) as max_ms, count(*) as count
    by function_name, dynamodb_operation
| sort avg_ms desc
```

### 対処法

**PAY_PER_REQUEST モードの場合（本プロジェクトのデフォルト）**:
PAY_PER_REQUEST は自動的にスケールするため、通常は手動対応不要。
ただし以下の場合は根本原因を調査する:

1. **Hot Partition**: 特定の `user_id` や `status` に対するリクエストが集中している
   - `status=ACTIVE` のアイテムが増え続けている場合、status-index の Hot Partition が発生する
   - 対処: 必要に応じてシャーディング（PK に乱数サフィックスを追加）

2. **N+1 問題**: Lambda 内でループ内に GetItem を呼んでいる
   - BatchGetItem への変更を検討

3. **不正なクロール**: 大量のリクエストが短時間に送られている
   - WAF を有効化し、レートリミットを設定する（prod 環境では標準装備）

---

## 3. Lambda スロットリング

### 症状

- CloudWatch アラーム `sap-dev-lambda-throttle` が ALARM
- API Gateway のログに `429 Too Many Requests`
- Lambda メトリクス `Throttles` が増加

### 調査ステップ

#### Step 1: スロットル状況を確認

```bash
# 各 Lambda のスロットル数を確認
for func in list-items get-item create-item update-item delete-item; do
  echo "=== sap-dev-$func ==="
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Throttles \
    --dimensions Name=FunctionName,Value="sap-dev-$func" \
    --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
    --period 300 \
    --statistics Sum \
    --output text
done
```

#### Step 2: 同時実行数の使用状況を確認

```bash
aws lambda get-account-settings --query 'AccountLimit'
```

#### Step 3: 急増したリクエストの発生源を特定

```
# API Gateway アクセスログから上位 IP とエンドポイントを集計
fields @timestamp, ip, httpMethod, resourcePath, status
| filter status = "429"
| stats count(*) as request_count by ip, httpMethod, resourcePath
| sort request_count desc
| limit 20
```

### 対処法

| 状況 | 対処 |
|---|---|
| アカウントの同時実行数上限に到達 | `aws lambda put-function-concurrency` で予約同時実行数を確保 |
| 特定 Lambda のみスロットル | 該当 Lambda の同時実行数を `reserved_concurrent_executions` で増加 |
| 不正な大量リクエスト | WAF の IP ベースのレートリミットを即時有効化（Terraform apply） |
| Cold Start 多発 | Provisioned Concurrency を一時的に設定（コスト増に注意） |

**緊急時の同時実行数調整**:

```bash
# 特定 Lambda の同時実行上限を設定（burst を防ぐ）
aws lambda put-function-concurrency \
  --function-name sap-dev-create-item \
  --reserved-concurrent-executions 100
```

---

## 4. Cognito 認証エラー急増

### 症状

- API Gateway のメトリクス `4XXError` が増加（特に 401）
- ユーザーから「ログインできない」という報告

### 調査ステップ

#### Step 1: 401 エラー率を確認

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApiGateway \
  --metric-name 4XXError \
  --dimensions Name=ApiName,Value=sap-dev-api \
  --start-time $(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum \
  --output table
```

#### Step 2: Cognito の認証ログを確認

```bash
# CloudTrail で Cognito API コールのエラーを確認
aws logs filter-log-events \
  --log-group-name "aws-controltower/CloudTrailLogs" \
  --filter-pattern '{ $.eventSource = "cognito-idp.amazonaws.com" && $.errorCode EXISTS }' \
  --start-time $(date -d '30 minutes ago' +%s)000 \
  --limit 50
```

#### Step 3: トークンの有効性を直接確認

```bash
# 新しいトークンを取得してテスト
TOKEN=$(aws cognito-idp initiate-auth \
  --auth-flow USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=testuser@example.com,PASSWORD=MyPassword123! \
  --client-id "$CLIENT_ID" \
  --query 'AuthenticationResult.IdToken' \
  --output text)

# API が正常に応答するか確認
curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  "$API_ENDPOINT/items"
```

### 原因別対処法

| 原因 | 確認方法 | 対処 |
|---|---|---|
| トークン有効期限切れ | `exp` クレームを確認 | クライアントにリフレッシュ処理を実装 |
| Cognito User Pool 設定変更 | CloudTrail で `UpdateUserPool` を検索 | 変更内容を確認・必要なら revert |
| App Client 設定変更 | Terraform の tfstate と実環境を比較 | `terraform plan` で差分確認 |
| 大量の認証試行（ブルートフォース） | CloudTrail の `InitiateAuth` エラーを集計 | Cognito の高度なセキュリティ機能を有効化 |

---

## 5. CloudWatch アラーム一覧

| アラーム名 | メトリクス | 閾値 | 対応手順 |
|---|---|---|---|
| `sap-dev-api-5xx-rate` | `ApiGateway 5XXError` | 5分間で10件以上 | [5xx 調査手順](#1-5xx-エラー急増の調査手順) |
| `sap-dev-lambda-error-rate` | `Lambda Errors` | 5分間で5件以上 | [5xx 調査手順](#1-5xx-エラー急増の調査手順) |
| `sap-dev-lambda-throttle` | `Lambda Throttles` | 5分間で1件以上 | [スロットリング手順](#3-lambda-スロットリング) |
| `sap-dev-dynamodb-throttle` | `DynamoDB ThrottledRequests` | 5分間で1件以上 | [DynamoDB 超過手順](#2-dynamodb-capacityunits-超過) |

### アラーム状態の一括確認

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix sap-dev \
  --state-value ALARM \
  --query 'MetricAlarms[].{Name:AlarmName, State:StateValue, Reason:StateReason}' \
  --output table
```

---

## 参考コマンド集

### Lambda の最新ログを確認

```bash
# 最近のログストリームから 100 行取得
aws logs tail /aws/lambda/sap-dev-create-item --follow
```

### デプロイ済みの Lambda バージョンを確認

```bash
for func in list-items get-item create-item update-item delete-item stream-processor; do
  echo -n "sap-dev-$func: "
  aws lambda get-function-configuration \
    --function-name "sap-dev-$func" \
    --query 'LastModified' \
    --output text
done
```

### 手動ロールバック（前バージョンの zip を再デプロイ）

```bash
# S3 の以前のバージョン一覧を確認
aws s3api list-object-versions \
  --bucket "sap-dev-lambda-deployment-$ACCOUNT_ID" \
  --prefix "lambda/create-item/" \
  --query 'Versions[].{Key:Key,LastModified:LastModified}' \
  --output table

# 特定バージョンでコードを更新
aws lambda update-function-code \
  --function-name sap-dev-create-item \
  --s3-bucket "sap-dev-lambda-deployment-$ACCOUNT_ID" \
  --s3-key "lambda/create-item/前のバージョンのキー.zip" \
  --architectures arm64
```
