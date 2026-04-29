# 運用ランブック: bedrock-multi-agent-ops-autopilot

## システム概要

AWS Bedrock Multi-Agent Collaborationパターンを用いた運用自動化システム。
EventBridgeが障害・コスト異常を検知し、Step Functions経由でSupervisor Agentを起動。
Supervisor Agentが状況を判断し、適切なSub-agentに調査・修復・レポートを委譲する。

```
EventBridge → Step Functions → Supervisor Agent
                                    ├─ Incident Investigator Agent
                                    ├─ Cost Optimizer Agent
                                    ├─ Remediation Agent（承認フロー必須）
                                    └─ Reporter Agent（Chatwork通知）
```

---

## 通常運用

### EventBridgeルールの確認

```bash
# コスト異常ルールの確認
aws events describe-rule \
  --name bmao-cost-anomaly \
  --region ap-northeast-1

# CloudWatchアラームルールの確認
aws events describe-rule \
  --name bmao-cloudwatch-alarm \
  --region ap-northeast-1
```

### Step Functionsの実行状況確認

```bash
# 最近の実行一覧（最新10件）
aws stepfunctions list-executions \
  --state-machine-arn $(aws stepfunctions list-state-machines \
    --query "stateMachines[?name=='bmao-ops-orchestrator'].stateMachineArn" \
    --output text \
    --region ap-northeast-1) \
  --max-results 10 \
  --region ap-northeast-1

# 実行履歴をDynamoDBで確認
aws dynamodb query \
  --table-name bmao-execution-history \
  --index-name status-index \
  --key-condition-expression "#s = :status" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":status": {"S": "RUNNING"}}' \
  --region ap-northeast-1
```

---

## 手動実行（テスト用）

### コスト異常テストイベントの投入

```bash
STATE_MACHINE_ARN=$(aws stepfunctions list-state-machines \
  --query "stateMachines[?name=='bmao-ops-orchestrator'].stateMachineArn" \
  --output text --region ap-northeast-1)

aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --name "manual-test-$(date +%Y%m%d%H%M%S)" \
  --input '{
    "event_type": "COST_ANOMALY",
    "event_detail": {
      "anomaly_id": "manual-test-001",
      "total_impact_usd": "55.00"
    }
  }' \
  --region ap-northeast-1
```

### CloudWatchアラームテストイベントの投入

```bash
aws stepfunctions start-execution \
  --state-machine-arn "$STATE_MACHINE_ARN" \
  --name "manual-alarm-$(date +%Y%m%d%H%M%S)" \
  --input '{
    "event_type": "CLOUDWATCH_ALARM",
    "event_detail": {
      "alarm_name": "test-high-cpu",
      "state": "ALARM",
      "reason": "CPU > 80% for 5 minutes"
    }
  }' \
  --region ap-northeast-1
```

---

## 承認フロー

Remediation Agentは必ず承認フローを経由して修復を実行する。
承認状態は `bmao-approval-requests` DynamoDBテーブルで管理される。

### 承認待ちリクエストの確認

```bash
aws dynamodb scan \
  --table-name bmao-approval-requests \
  --filter-expression "#s = :pending" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":pending": {"S": "PENDING"}}' \
  --region ap-northeast-1
```

### 承認操作（APPROVED に更新）

```bash
REQUEST_ID="<request_idをここに入力>"

aws dynamodb update-item \
  --table-name bmao-approval-requests \
  --key "{\"request_id\": {\"S\": \"${REQUEST_ID}\"}}" \
  --update-expression "SET #s = :approved, approved_by = :approver, approved_at = :ts" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values "{
    \":approved\": {\"S\": \"APPROVED\"},
    \":approver\": {\"S\": \"$(whoami)\"},
    \":ts\": {\"S\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}
  }" \
  --region ap-northeast-1
```

### 却下操作（REJECTED に更新）

```bash
aws dynamodb update-item \
  --table-name bmao-approval-requests \
  --key "{\"request_id\": {\"S\": \"${REQUEST_ID}\"}}" \
  --update-expression "SET #s = :rejected" \
  --expression-attribute-names '{"#s": "status"}' \
  --expression-attribute-values '{":rejected": {"S": "REJECTED"}}' \
  --region ap-northeast-1
```

---

## トラブルシューティング

### Agentエラー時の確認箇所

**1. Step Functions実行ログ**

```bash
# 失敗した実行の詳細を確認
EXECUTION_ARN="<実行ARNをここに入力>"
aws stepfunctions describe-execution \
  --execution-arn "$EXECUTION_ARN" \
  --region ap-northeast-1
```

**2. CloudWatch Logsでの詳細確認**

```bash
# Step Functionsログ
aws logs tail /aws/stepfunctions/bmao-ops-orchestrator \
  --follow --region ap-northeast-1

# Supervisor Agent実行ログ（Lambda経由の場合）
aws logs tail /aws/lambda/bmao-incident-investigator \
  --follow --region ap-northeast-1
```

**3. Bedrock AgentのInvocation確認**

```bash
# Bedrock Agent呼び出しメトリクスをCloudWatchで確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Bedrock \
  --metric-name Invocations \
  --dimensions Name=AgentId,Value=<AGENT_ID> \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 300 \
  --statistics Sum \
  --region ap-northeast-1
```

**4. Guardrailによるブロック確認**

Bedrockのガードレールが破壊的操作をブロックした場合、CloudWatch Logsに以下のメッセージが記録される:
`この操作は安全上の理由から禁止されています`

ブロックが意図的でない場合は、`terraform/modules/agents/main.tf` の `topic_policy_config` を確認する。

---

## コスト管理

### Bedrock呼び出し回数の確認

```bash
# 過去24時間のBedrock Agentトークン消費量
aws cloudwatch get-metric-statistics \
  --namespace AWS/Bedrock \
  --metric-name InputTokenCount \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Sum \
  --region ap-northeast-1
```

### コストダッシュボード

AWS Cost Explorer で以下のフィルタを適用:
- サービス: Amazon Bedrock
- タグ: `Project = bedrock-multi-agent-ops-autopilot`

月額上限の目安: **$20**。これを超える場合はStep FunctionsのEventBridgeルールを一時無効化すること。

---

## 緊急停止

EventBridgeルールを無効化してシステムへの自動トリガーを停止する。

```bash
# コスト異常ルールを無効化
aws events disable-rule \
  --name bmao-cost-anomaly \
  --region ap-northeast-1

# CloudWatchアラームルールを無効化
aws events disable-rule \
  --name bmao-cloudwatch-alarm \
  --region ap-northeast-1

echo "EventBridgeルールを無効化しました。手動実行も停止する場合はAWS Consoleで対応してください。"
```

### ルールの再有効化

```bash
aws events enable-rule \
  --name bmao-cost-anomaly \
  --region ap-northeast-1

aws events enable-rule \
  --name bmao-cloudwatch-alarm \
  --region ap-northeast-1
```
