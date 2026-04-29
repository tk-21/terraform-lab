# ✅Phase 3: Supervisor Agent + Step Functions + EventBridgeトリガー

## Phase 1-2で作成したもの（サマリー）

**Phase 1（基盤）**:
- S3: `bmao-reports-{account_id}` / DynamoDB: `bmao-execution-history`, `bmao-approval-requests`
- SSM: `/bmao/chatwork/room_id`, `/bmao/chatwork/api_token`
- IAM: `bmao-lambda-base-role`, `bmao-supervisor-agent-role`

**Phase 2（Sub-agents）**:
- Lambda × 4: `bmao-incident-investigator`, `bmao-cost-optimizer`, `bmao-remediation`, `bmao-reporter`
- Bedrock Agent × 3（Sub-agents）: Incident Investigator / Cost Optimizer / Remediation
- Bedrock Guardrails: 破壊的操作をDENY
- 各Sub-agentはBedrock Agent Aliasを持つ
- Remediationは必ず `create_approval_request` → `check_approval_status` → `execute` の順序を強制

---

## このフェーズで作成するもの

Supervisor Agentの定義、Step Functionsによるオーケストレーション、EventBridgeトリガーを実装し、
Multi-Agent Collaborationのエンドツーエンドフローを完成させる。

---

## タスク一覧

### 1. Supervisor Agent Instructionファイルの作成

**ファイル**: `agents/supervisor/instruction.txt`

以下の内容で作成:
```
あなたはAWS運用自動化のSupervisor Agentです。
EventBridgeから障害検知・コスト異常のイベントを受け取り、
適切なSub-agentに調査・修復・レポートを委譲してください。

## 判断フロー

### 障害イベントを受け取った場合:
1. Incident Investigator Agentに調査を委譲する
2. 調査結果を受け取り、根本原因を判断する
3. 修復が必要と判断した場合:
   - 低リスク（設定変更・SSMコマンド）: Remediation Agentに委譲
   - 高リスク（インスタンス停止など）: Reporter Agentで承認依頼レポートを作成
4. Reporter Agentに最終レポート生成を委譲する

### コスト異常イベントを受け取った場合:
1. Cost Optimizer Agentに分析を委譲する
2. 分析結果を受け取り、対応を判断する:
   - 未使用リソース（EBS/EIP）: Remediation Agentに承認フロー付きで委譲
   - リソースサイジング推奨: Reporter Agentでレポートのみ作成
3. Reporter Agentに最終レポート生成を委譲する

## 重要ルール
- Sub-agentへの委譲は順序を守ること（調査→判断→修復→レポート）
- Remediationは必ず承認フロー経由であることを確認すること
- すべての実行結果はReporter Agentを通じてChatworkに通知すること
- 判断できない場合は「人間に確認が必要」とReporter Agentに伝えること
```

### 2. Supervisor AgentのBedrock Agent定義

`terraform/modules/agents/supervisor.tf` を作成:

```hcl
# Supervisor Agent本体
resource "aws_bedrock_agent" "supervisor" {
  agent_name              = "${local.prefix}-supervisor"
  agent_resource_role_arn = var.supervisor_agent_role_arn
  foundation_model        = "anthropic.claude-3-7-sonnet-20250219-v1:0"
  instruction             = file("${path.module}/../../../agents/supervisor/instruction.txt")
  description             = "AWS運用タスクを自律的に判断しSub-agentに委譲するSupervisorエージェント"

  # Multi-Agent Collaborationを有効化
  # Sub-agentはcollaboration設定で定義する
  agent_collaboration = "SUPERVISOR"  # SupervisorモードでSub-agent委譲を有効化

  # メモリ設定（セッション間でコンテキストを保持）
  memory_configuration {
    enabled_memory_types = ["SESSION_SUMMARY"]
    storage_days         = 30
  }

  # Guardrails適用
  guardrail_configuration {
    guardrail_id      = var.guardrail_id
    guardrail_version = "DRAFT"
  }

  tags = local.common_tags
}

# SupervisorのSub-agent委譲設定
resource "aws_bedrock_agent_collaborator" "incident_investigator" {
  agent_id                   = aws_bedrock_agent.supervisor.id
  agent_version              = "DRAFT"
  collaboration_instruction  = "障害調査が必要な場合にこのエージェントに委譲する"
  collaborator_name          = "IncidentInvestigator"

  agent_descriptor {
    alias_arn = var.incident_investigator_alias_arn
  }
}

resource "aws_bedrock_agent_collaborator" "cost_optimizer" {
  agent_id                   = aws_bedrock_agent.supervisor.id
  agent_version              = "DRAFT"
  collaboration_instruction  = "コスト異常分析・最適化推奨が必要な場合にこのエージェントに委譲する"
  collaborator_name          = "CostOptimizer"

  agent_descriptor {
    alias_arn = var.cost_optimizer_alias_arn
  }
}

resource "aws_bedrock_agent_collaborator" "remediation" {
  agent_id                   = aws_bedrock_agent.supervisor.id
  agent_version              = "DRAFT"
  collaboration_instruction  = "承認済みの修復アクション実行が必要な場合にこのエージェントに委譲する"
  collaborator_name          = "Remediation"

  agent_descriptor {
    alias_arn = var.remediation_alias_arn
  }
}

# Supervisor Agentエイリアス
resource "aws_bedrock_agent_alias" "supervisor" {
  agent_alias_name = "production"
  agent_id         = aws_bedrock_agent.supervisor.id
  description      = "本番環境用Supervisorエイリアス"
  tags             = local.common_tags
}
```

### 3. Step Functions ステートマシンの実装

**ファイル**: `terraform/modules/stepfunctions/main.tf` と対応するASL定義

**Amazon States Language (ASL) ファイル**: `stepfunctions/ops_orchestrator.asl.json`

以下の構造で実装:

```json
{
  "Comment": "AWS運用自動化オーケストレーター - Supervisor Agentを呼び出し結果を管理",
  "StartAt": "RecordExecutionStart",
  "States": {
    "RecordExecutionStart": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:putItem",
      "Parameters": {
        "TableName": "${execution_history_table}",
        "Item": {
          "execution_id": {"S.$": "$$.Execution.Name"},
          "timestamp": {"S.$": "$$.Execution.StartTime"},
          "status": {"S": "RUNNING"},
          "event_type": {"S.$": "$.event_type"},
          "ttl": {"N": "期限タイムスタンプ"}
        }
      },
      "ResultPath": null,
      "Next": "InvokeSupervisorAgent"
    },
    "InvokeSupervisorAgent": {
      "Type": "Task",
      "Resource": "arn:aws:states:::bedrock:invokeAgent",
      "Parameters": {
        "AgentId": "${supervisor_agent_id}",
        "AgentAliasId": "${supervisor_agent_alias_id}",
        "SessionId.$": "$$.Execution.Name",
        "InputText.$": "States.Format('イベントタイプ: {}, 詳細: {}', $.event_type, States.JsonToString($.event_detail))"
      },
      "TimeoutSeconds": 300,
      "Retry": [
        {
          "ErrorEquals": ["Bedrock.ThrottlingException"],
          "IntervalSeconds": 30,
          "MaxAttempts": 3,
          "BackoffRate": 2
        }
      ],
      "Catch": [
        {
          "ErrorEquals": ["States.ALL"],
          "Next": "RecordFailure"
        }
      ],
      "Next": "RecordSuccess"
    },
    "RecordSuccess": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${execution_history_table}",
        "Key": {
          "execution_id": {"S.$": "$$.Execution.Name"},
          "timestamp": {"S.$": "$$.Execution.StartTime"}
        },
        "UpdateExpression": "SET #s = :status",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {":status": {"S": "SUCCEEDED"}}
      },
      "End": true
    },
    "RecordFailure": {
      "Type": "Task",
      "Resource": "arn:aws:states:::dynamodb:updateItem",
      "Parameters": {
        "TableName": "${execution_history_table}",
        "Key": {
          "execution_id": {"S.$": "$$.Execution.Name"},
          "timestamp": {"S.$": "$$.Execution.StartTime"}
        },
        "UpdateExpression": "SET #s = :status, error_details = :err",
        "ExpressionAttributeNames": {"#s": "status"},
        "ExpressionAttributeValues": {
          ":status": {"S": "FAILED"},
          ":err": {"S.$": "States.JsonToString($)"}
        }
      },
      "End": true
    }
  }
}
```

**terraform/modules/stepfunctions/main.tf**:
- `aws_sfn_state_machine` リソース
- IAMロール: Step Functionsが `bedrock:InvokeAgent` と DynamoDB操作を実行できる権限
- CloudWatch Logsへの実行ログ出力設定
- 日本語コメント: 「Supervisor Agent呼び出しのラッパー。実行履歴管理とタイムアウト・リトライ制御が責務」

### 4. EventBridgeルールの実装

`terraform/modules/foundation/eventbridge.tf` を作成:

#### コスト異常検知ルール
```hcl
resource "aws_cloudwatch_event_rule" "cost_anomaly" {
  name        = "${local.prefix}-cost-anomaly"
  description = "AWS Cost Anomaly Detectionの異常検知イベントをキャプチャ"

  event_pattern = jsonencode({
    source      = ["aws.ce"]
    detail-type = ["Cost Anomaly Detection Alert"]
  })
  tags = local.common_tags
}

resource "aws_cloudwatch_event_target" "cost_anomaly_to_sfn" {
  rule     = aws_cloudwatch_event_rule.cost_anomaly.name
  arn      = var.state_machine_arn
  role_arn = aws_iam_role.eventbridge_sfn_role.arn

  input_transformer {
    input_paths = {
      anomaly_id   = "$.detail.anomalyId"
      total_impact = "$.detail.impact.totalImpact"
    }
    input_template = <<EOF
{
  "event_type": "COST_ANOMALY",
  "event_detail": {
    "anomaly_id": "<anomaly_id>",
    "total_impact_usd": "<total_impact>"
  }
}
EOF
  }
}
```

#### CloudWatchアラームルール
```hcl
resource "aws_cloudwatch_event_rule" "cloudwatch_alarm" {
  name        = "${local.prefix}-cloudwatch-alarm"
  description = "CloudWatchアラームのALARM状態遷移をキャプチャ"

  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })
  tags = local.common_tags
}
```

#### EventBridge → Step Functions用IAMロール
```hcl
resource "aws_iam_role" "eventbridge_sfn_role" {
  name = "${local.prefix}-eventbridge-sfn-role"
  # 日本語コメント: 「EventBridgeがStep Functionsを起動するための最小権限ロール」
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
}
```

### 5. Cost Anomaly Detection Monitorの設定

```hcl
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name         = "${local.prefix}-service-monitor"
  monitor_type = "DIMENSIONAL"

  monitor_dimension = "SERVICE"
  # 日本語コメント: 「サービス単位でコスト異常を検知。個別サービスの急激なコスト増加をキャッチ」
}

resource "aws_ce_anomaly_subscription" "ops_subscription" {
  name      = "${local.prefix}-ops-subscription"
  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = [tostring(var.alert_threshold_cost_usd)]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }

  frequency = "IMMEDIATE"

  monitor_arn_list = [aws_ce_anomaly_monitor.service_monitor.arn]

  subscriber {
    address = "arn:aws:events:ap-northeast-1:${local.account_id}:event-bus/default"
    type    = "SNS"
  }
}
```

### 6. 統合テスト用スクリプトの作成

**ファイル**: `tests/integration/test_e2e.py`

以下のテストシナリオを実装:

```python
"""
E2Eテスト: Multi-Agent Ops Autopilot

テストシナリオ:
1. コスト異常イベントをStep Functionsに直接投入
2. Supervisor Agentが起動することを確認
3. DynamoDB実行履歴にSUCCEEDEDが記録されることを確認（タイムアウト: 5分）
4. Chatwork通知の送信を確認（DynamoDBのstatus参照）
"""
import boto3
import json
import time
import uuid

def test_cost_anomaly_flow():
    sfn_client = boto3.client('stepfunctions', region_name='ap-northeast-1')
    ddb_client = boto3.client('dynamodb', region_name='ap-northeast-1')

    execution_name = f"test-{uuid.uuid4().hex[:8]}"

    # テストイベント投入
    test_input = {
        "event_type": "COST_ANOMALY",
        "event_detail": {
            "anomaly_id": "test-anomaly-001",
            "total_impact_usd": "55.00"
        }
    }

    # ... ポーリングロジックとアサーション実装
```

### 7. docs/runbook.md の作成

以下のセクションを含む運用ランブックを作成:

- **システム概要**: Multi-Agent Collaborationパターンの説明
- **通常運用**: EventBridgeトリガーの確認方法
- **手動実行**: Step Functionsを直接起動する方法（テスト用）
- **承認フロー**: DynamoDB `bmao-approval-requests` テーブルでの承認操作手順
- **トラブルシューティング**: Agentがエラーになった場合の確認箇所
- **コスト管理**: Bedrock呼び出し回数の確認方法（CloudWatch Metrics）
- **緊急停止**: EventBridgeルールを無効化する手順

---

## 完了条件

- [ ] Supervisor AgentがSub-agent 3種を委譲できる設定になっていること
- [ ] Step Functionsが `bedrock:InvokeAgent` でSupervisorを呼び出せること
- [ ] EventBridgeがCost AnomalyとCloudWatch Alarmを検知してStep Functionsを起動できること
- [ ] `terraform validate` と `terraform plan` が通ること
- [ ] 統合テストスクリプトが実装されていること
- [ ] ランブックが作成されていること

---

## 次フェーズの予告

Phase 4では以下を実施:
- 実際のAWS環境へのデプロイ（`terraform apply`）
- Step Functionsのテスト実行（テストイベント投入）
- Chatwork通知の動作確認
- GitHub公開用README.mdの作成
- Zenn記事の下書き作成