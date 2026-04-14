# 障害対応手順書（Runbook）

> **対象システム**: serverless-event-pipeline (sep)
> **対象環境**: dev / prod
> **最終更新**: 2024-01-15
> **オーナー**: platform-team

---

## 共通確認事項

障害対応を開始する前に以下を確認してください。

```bash
# 環境変数の設定
export ENV=dev   # または prod
export REGION=ap-northeast-1
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# ダッシュボードを開く
echo "CloudWatch Dashboard:"
echo "https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#dashboards:name=sep-${ENV}-dashboard"
```

---

## 1. DLQ にメッセージが蓄積された場合

### 症状

CloudWatch Alarm `sep-<env>-ingest-dlq-messages-alarm` が ALARM 状態になる。
メール通知（SNS: `sep-<env>-alerts`）が届く。

### 原因調査

**Step 1: DLQ のメッセージ件数を確認する**

```bash
QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name sep-${ENV}-ingest-dlq \
  --query QueueUrl --output text)

aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

**Step 2: DLQ メッセージの内容を確認する（最大 10 件）**

```bash
# メッセージを受信（可視性タイムアウト 60 秒）
aws sqs receive-message \
  --queue-url "${QUEUE_URL}" \
  --max-number-of-messages 10 \
  --attribute-names All \
  --message-attribute-names All \
  --visibility-timeout 60 \
  | jq '.Messages[] | {
      MessageId: .MessageId,
      失敗理由: .MessageAttributes.ErrorType.StringValue,
      試行回数: .MessageAttributes.RetryCount.StringValue,
      本文: (.Body | fromjson)
    }'
```

**Step 3: Lambda のエラーログを確認する**

```bash
# CloudWatch Logs Insights で直近のエラーを抽出
aws logs start-query \
  --log-group-names "/aws/lambda/sep-${ENV}-ingestor" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, level, message, error, correlation_id
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 50
  '

# クエリ結果を取得（QUERY_ID は上記コマンドの出力から取得）
aws logs get-query-results --query-id <QUERY_ID>
```

**Step 4: X-Ray でエラートレースを確認する**

```bash
# 直近 1 時間のエラートレースを取得
aws xray get-trace-summaries \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --filter-expression 'fault = true AND annotation.service = "sep-ingestor"' \
  | jq '.TraceSummaries[] | {Id: .Id, Duration: .Duration, HasError: .HasError}'
```

### 対処

**一時エラー（Throttling・タイムアウト・接続エラー）の場合**

dlq-handler が自動で再エンキューします。以下で対応状況を確認します。

```bash
# dlq-handler の実行ログを確認
aws logs tail /aws/lambda/sep-${ENV}-dlq-handler --follow
```

5 分以内に DLQ のメッセージ数が減少しない場合は、dlq-handler を手動起動します。

```bash
aws lambda invoke \
  --function-name sep-${ENV}-dlq-handler \
  --qualifier live \
  --payload '{"source": "manual-runbook"}' \
  /tmp/dlq-handler-response.json

cat /tmp/dlq-handler-response.json
```

**恒久エラー（バリデーション失敗・不正データ）の場合**

S3 dead-letter-archive を確認してデータを修正します。

```bash
# dead-letter-archive の内容を確認
aws s3 ls s3://sep-${ENV}-dead-letter-archive-${ACCOUNT_ID}/ --recursive \
  | sort -k1,2 \
  | tail -20

# 最新の恒久エラーメッセージを確認
aws s3 cp \
  s3://sep-${ENV}-dead-letter-archive-${ACCOUNT_ID}/permanent/$(date +%Y-%m-%d)/ \
  /tmp/dead-letters/ \
  --recursive

# gzip ファイルを展開して確認
gunzip -c /tmp/dead-letters/*.json.gz | jq .
```

データを修正して再投入する場合:

```bash
# 修正済みメッセージを SQS に送信
aws sqs send-message \
  --queue-url $(aws sqs get-queue-url --queue-name sep-${ENV}-ingest-queue --query QueueUrl --output text) \
  --message-body '{"entity_id":"USER#u123","event_type":"click","payload":{"page":"top"}}'
```

---

## 2. Kinesis IteratorAge（処理遅延）

### 症状

CloudWatch Alarm `sep-<env>-kinesis-iterator-age-alarm` が ALARM 状態になる。
`GetRecords.IteratorAgeMilliseconds` が 60,000 ms（60 秒）を超えている。

### 原因調査

**Step 1: 現在の IteratorAge を確認する**

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name GetRecords.IteratorAgeMilliseconds \
  --dimensions Name=StreamName,Value=sep-${ENV}-events-stream \
  --start-time $(date -d '30 minutes ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Maximum \
  | jq '.Datapoints | sort_by(.Timestamp) | .[-10:] | .[] | {時刻: .Timestamp, IteratorAge_ms: .Maximum}'
```

**Step 2: transformer Lambda のエラー・スロットルを確認する**

```bash
# エラー率を確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=sep-${ENV}-transformer \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum

# スロットル（同時実行数超過）を確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Throttles \
  --dimensions Name=FunctionName,Value=sep-${ENV}-transformer \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum
```

**Step 3: Kinesis ストリームのメトリクスを確認する**

```bash
# 書込レコード数（ingestors 側の突発増加を確認）
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name PutRecords.Records \
  --dimensions Name=StreamName,Value=sep-${ENV}-events-stream \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum

# ReadProvisionedThroughputExceeded: 読込スループット超過
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name ReadProvisionedThroughputExceeded \
  --dimensions Name=StreamName,Value=sep-${ENV}-events-stream \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum
```

### 対処

**Lambda スロットルが原因の場合**

```bash
# 現在の同時実行数設定を確認
aws lambda get-function-concurrency \
  --function-name sep-${ENV}-transformer

# reserved_concurrent_executions を増やす（アカウント上限に注意）
aws lambda put-function-concurrency \
  --function-name sep-${ENV}-transformer \
  --reserved-concurrent-executions 100
```

**DynamoDB スロットルが原因の場合**

```bash
# DynamoDB スロットルを確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ThrottledRequests \
  --dimensions Name=TableName,Value=sep-${ENV}-events \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum

# PAY_PER_REQUEST モードの場合、自動スケール済みのはず
# バースト超過の場合は Lambda の reserved_concurrent_executions で流量を制御する
```

**Kinesis シャード容量不足の場合**

```bash
# シャード数を増やす（コスト増加に注意: +$15/shard/月）
aws kinesis update-shard-count \
  --stream-name sep-${ENV}-events-stream \
  --target-shard-count 2 \
  --scaling-type UNIFORM_SCALING
```

---

## 3. Lambda エラー率上昇

### 症状

CloudWatch Alarm `sep-<env>-lambda-error-rate-alarm` が ALARM 状態になる。
X-Ray サービスマップで特定の Lambda に高エラー率が表示される。

### 原因調査

**Step 1: Log Insights でエラーの傾向を把握する**

```bash
# 直近 1 時間のエラーを関数別に集計
aws logs start-query \
  --log-group-names \
    "/aws/lambda/sep-${ENV}-ingestor" \
    "/aws/lambda/sep-${ENV}-transformer" \
    "/aws/lambda/sep-${ENV}-aggregator" \
    "/aws/lambda/sep-${ENV}-dlq-handler" \
  --start-time $(date -d '1 hour ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @log, level, message, error, error_type
    | filter level = "ERROR"
    | stats count(*) as error_count by @log, error_type
    | sort error_count desc
    | limit 20
  '
```

**Step 2: 特定の関数のエラーを詳細に確認する（例: transformer）**

```bash
aws logs start-query \
  --log-group-names "/aws/lambda/sep-${ENV}-transformer" \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, level, message, error, error_type, correlation_id, entity_id
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 50
  '
```

**Step 3: デプロイとエラー急増のタイミングを確認する**

```bash
# Lambda の最新バージョン発行日時を確認
aws lambda list-versions-by-function \
  --function-name sep-${ENV}-transformer \
  --query 'Versions[-3:] | [].{Version: Version, LastModified: LastModified, Description: Description}' \
  | jq .

# live エイリアスの現在の設定を確認（カナリアウェイトが残っていないか）
aws lambda get-alias \
  --function-name sep-${ENV}-transformer \
  --name live \
  | jq '{FunctionVersion: .FunctionVersion, RoutingConfig: .RoutingConfig}'
```

### 対処

**デプロイ直後にエラーが急増した場合: 前バージョンにロールバック**

```bash
# 安定バージョン番号を確認（デプロイ前のバージョン）
STABLE_VERSION=$(aws lambda list-versions-by-function \
  --function-name sep-${ENV}-transformer \
  --query 'Versions[-2].Version' \
  --output text)

echo "ロールバック先: v${STABLE_VERSION}"

# live エイリアスをカナリアなしで安定バージョンに戻す
aws lambda update-alias \
  --function-name sep-${ENV}-transformer \
  --name live \
  --function-version "${STABLE_VERSION}" \
  --routing-config '{}'

echo "ロールバック完了"
```

**コードに問題がある場合の緊急停止**

```bash
# Lambda の ESM を無効化してイベント処理を停止する
ESM_UUID=$(aws lambda list-event-source-mappings \
  --function-name sep-${ENV}-transformer \
  --query 'EventSourceMappings[0].UUID' \
  --output text)

aws lambda update-event-source-mapping \
  --uuid "${ESM_UUID}" \
  --no-enabled

echo "ESM を無効化しました。Kinesis のメッセージは蓄積されます（最大 24h 保持）"
echo "修正後に再有効化: aws lambda update-event-source-mapping --uuid ${ESM_UUID} --enabled"
```

---

## 4. 手動再処理（DLQ から元キューへの転送）

### 用途

dlq-handler の自動再処理が機能しない場合や、特定のメッセージを選択して再処理する場合に使います。

### 手順

**Step 1: DLQ のメッセージ件数を確認する**

```bash
DLQ_URL=$(aws sqs get-queue-url \
  --queue-name sep-${ENV}-ingest-dlq \
  --query QueueUrl --output text)

QUEUE_URL=$(aws sqs get-queue-url \
  --queue-name sep-${ENV}-ingest-queue \
  --query QueueUrl --output text)

aws sqs get-queue-attributes \
  --queue-url "${DLQ_URL}" \
  --attribute-names ApproximateNumberOfMessages \
  | jq '.Attributes.ApproximateNumberOfMessages'
```

**Step 2: AWS マネジメントコンソールからの一括転送（推奨）**

1. [SQS コンソール](https://ap-northeast-1.console.aws.amazon.com/sqs/v3/home) を開く
2. `sep-<env>-ingest-dlq` を選択
3. 「デッドレターキューの再ドライブ」ボタンをクリック
4. 転送先に `sep-<env>-ingest-queue` を指定
5. 転送するメッセージ数を指定して実行

**Step 3: AWS CLI からの手動転送（少量の場合）**

```bash
#!/bin/bash
# DLQ から元キューへメッセージを転送するスクリプト
# 使い方: bash scripts/redrive-dlq.sh [転送件数の上限]

MAX_MESSAGES=${1:-100}
TRANSFERRED=0

echo "DLQ → 元キューへの転送を開始します（上限: ${MAX_MESSAGES} 件）"

while [ "${TRANSFERRED}" -lt "${MAX_MESSAGES}" ]; do
  # DLQ からメッセージを受信（最大 10 件）
  MESSAGES=$(aws sqs receive-message \
    --queue-url "${DLQ_URL}" \
    --max-number-of-messages 10 \
    --visibility-timeout 30 \
    --attribute-names All \
    --message-attribute-names All)

  COUNT=$(echo "${MESSAGES}" | jq '.Messages | length')
  if [ "${COUNT}" -eq 0 ]; then
    echo "転送完了: DLQ にメッセージがありません"
    break
  fi

  # 元キューに送信して DLQ から削除
  echo "${MESSAGES}" | jq -c '.Messages[]' | while read -r MSG; do
    BODY=$(echo "${MSG}" | jq -r '.Body')
    RECEIPT=$(echo "${MSG}" | jq -r '.ReceiptHandle')

    # 元キューに送信
    aws sqs send-message \
      --queue-url "${QUEUE_URL}" \
      --message-body "${BODY}" \
      > /dev/null

    # DLQ から削除
    aws sqs delete-message \
      --queue-url "${DLQ_URL}" \
      --receipt-handle "${RECEIPT}"

    TRANSFERRED=$((TRANSFERRED + 1))
    echo "  転送済み: ${TRANSFERRED} 件"
  done
done

echo "完了: 合計 ${TRANSFERRED} 件を転送しました"
```

---

## 5. 統合テスト失敗によるカナリアロールバック後の調査

### 症状

GitHub Actions CD ワークフローの `promote-or-rollback` ジョブが「Lambda: Rollback + Alert」で完了する。
SNS から `[ROLLBACK] sep-dev パイプライン統合テスト失敗` メールが届く。

### 調査手順

**Step 1: GitHub Actions のログを確認する**

```
GitHub リポジトリ → Actions → 失敗したワークフロー実行を開く
integration-test ジョブのログを展開して失敗の詳細を確認する
```

**Step 2: どのバージョンにロールバックされたかを確認する**

```bash
# 各 Lambda の live エイリアスの現在のバージョンを確認
for FUNC in ingestor transformer aggregator dlq-handler; do
  echo -n "sep-${ENV}-${FUNC}: "
  aws lambda get-alias \
    --function-name "sep-${ENV}-${FUNC}" \
    --name live \
    --query '{Version: FunctionVersion, Routing: RoutingConfig}' \
    --output json
done
```

**Step 3: 失敗した新バージョンのコードを確認する**

```bash
# 最新バージョンの詳細を確認
aws lambda get-function \
  --function-name sep-${ENV}-transformer \
  --qualifier $(aws lambda list-versions-by-function \
    --function-name sep-${ENV}-transformer \
    --query 'Versions[-1].Version' \
    --output text) \
  --query 'Configuration.{Version: Version, LastModified: LastModified, Description: Description}'
```

**Step 4: 修正後に再デプロイする**

1. コードを修正してコミット・プッシュ
2. PR を作成して CI をパスさせる
3. main マージ後に CD が自動実行される

---

## 6. DynamoDB スロットリング

### 症状

CloudWatch Alarm `sep-<env>-dynamodb-throttle-alarm` が ALARM 状態になる。

### 原因調査

```bash
# スロットルの詳細を確認（オペレーション別）
aws cloudwatch get-metric-statistics \
  --namespace AWS/DynamoDB \
  --metric-name ThrottledRequests \
  --dimensions \
    Name=TableName,Value=sep-${ENV}-events \
    Name=Operation,Value=PutItem \
  --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 \
  --statistics Sum
```

### 対処

PAY_PER_REQUEST モードは AWS が自動スケールするため、通常は一時的なバースト超過で解消します。

継続する場合は Lambda の同時実行数で流量を制限します。

```bash
# transformer の同時実行数を制限してDynamoDB への書込を抑制する
aws lambda put-function-concurrency \
  --function-name sep-${ENV}-transformer \
  --reserved-concurrent-executions 10
```

スロットルが解消したら制限を解除します。

```bash
aws lambda delete-function-concurrency \
  --function-name sep-${ENV}-transformer
```

---

## アラーム一覧

| アラーム名 | 閾値 | 対応 Runbook |
|---|---|---|
| `sep-<env>-ingest-dlq-messages-alarm` | DLQ メッセージ >= 1 | セクション 1 |
| `sep-<env>-transform-dlq-messages-alarm` | DLQ メッセージ >= 1 | セクション 1 |
| `sep-<env>-kinesis-iterator-age-alarm` | IteratorAge >= 60,000 ms | セクション 2 |
| `sep-<env>-lambda-error-rate-alarm` | エラー率 >= 5% / 5 分 | セクション 3 |
| `sep-<env>-lambda-throttles-alarm` | スロットル >= 10 / 5 分 | セクション 3 |
| `sep-<env>-lambda-cold-start-alarm` | コールドスタート >= 20 / 5 分 | — |
| `sep-<env>-dynamodb-throttle-alarm` | スロットル >= 1 / 5 分 | セクション 6 |
