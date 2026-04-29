# ✅Phase 2: Sub-Agent Lambda実装 + Bedrock Agent定義

## Phase 1で作成したもの（サマリー）

- `terraform/modules/foundation/`: S3/DynamoDB/SSM/IAM/CloudWatch Logsの基盤リソース
- プレフィックス: `bmao`
- Lambda基本実行ロール ARN: `module.foundation.lambda_base_role_arn`
- Supervisor Agent用ロール ARN: `module.foundation.supervisor_agent_role_arn`
- 通知先: Chatwork（SSMから `room_id` と `api_token` を取得）
- DynamoDB: `bmao-execution-history` / `bmao-approval-requests`
- S3: `bmao-reports-{account_id}`

---

## このフェーズで作成するもの

Sub-agent 3種のLambda（Action Groups）と、Bedrock Agent定義 + Guardrailsを実装する。

---

## タスク一覧

### 1. lambda/incident_investigator/ の実装

**ファイル**: `lambda/incident_investigator/handler.py`

Action Groupとして以下の関数を実装:

#### `investigate_cloudwatch_alarms`
- 入力: `{ "time_range_minutes": int, "namespace": str (optional) }`
- 処理:
  - CloudWatch `describe_alarms` でALARM状態のアラーム一覧取得
  - 各アラームの `get_metric_statistics` で直近のメトリクス値取得
  - 日本語コメント: 「Supervisorから障害調査を委譲された際の最初の調査ステップ」
- 出力: アラーム名・状態・メトリクス値のJSON

#### `investigate_xray_traces`
- 入力: `{ "service_name": str, "time_range_minutes": int }`
- 処理:
  - X-Ray `get_service_graph` でサービスマップ取得
  - `get_trace_summaries` でエラートレース抽出
  - 日本語コメント: 「マイクロサービス間の障害伝播経路を特定するためのトレース調査」
- 出力: エラーレート・レイテンシ・障害サービスのJSON

#### `check_config_compliance`
- 入力: `{ "resource_type": str (optional) }`
- 処理:
  - AWS Config `get_compliance_summary_by_config_rule` で非準拠リソース取得
  - 日本語コメント: 「設定変更が障害原因でないかConfigルールで確認」
- 出力: 非準拠ルール名・リソースIDのJSON

**共通実装要件**:
- AWS Lambda Powertools: Logger/Tracer/Metrics使用
- エラー時は `{"error": str, "action": "investigated"}` を返す（エージェントが判断継続できるように）
- `requirements.txt`: `aws-lambda-powertools>=2.0`, `boto3>=1.34`

---

### 2. lambda/cost_optimizer/ の実装

**ファイル**: `lambda/cost_optimizer/handler.py`

#### `get_cost_anomalies`
- 入力: `{ "lookback_days": int (default: 7) }`
- 処理:
  - Cost Explorer `get_anomalies` で異常コスト取得
  - 影響金額でソート
  - 日本語コメント: 「コスト異常の一覧を取得。Supervisorがコスト最適化タスクを判断する際の入力」
- 出力: サービス名・異常金額・期間のJSON

#### `get_rightsizing_recommendations`
- 入力: `{}` （引数なし）
- 処理:
  - Cost Explorer `get_rightsizing_recommendation` でEC2最適化推奨取得
  - 推定削減額でソート
  - 日本語コメント: 「過剰スペックなEC2インスタンスの最適化候補。自動実行せず推奨のみ返す」
- 出力: インスタンスID・推奨タイプ・削減額のJSON

#### `get_unused_resources`
- 入力: `{ "resource_types": list (default: ["EBS", "EIP", "RDS"]) }`
- 処理:
  - EBS: `describe_volumes` でavailable状態（未アタッチ）ボリューム取得
  - EIP: `describe_addresses` で未関連付けEIP取得
  - 日本語コメント: 「削除候補リソースの検出。実際の削除はRemediationAgentが承認後に実行」
- 出力: リソースID・タイプ・推定月額コストのJSON

---

### 3. lambda/remediation/ の実装

**ファイル**: `lambda/remediation/handler.py`

**重要**: このLambdaのIAMロールには以下を**絶対に付与しない**:
- `iam:*`
- `organizations:*`
- `ec2:TerminateInstances`（削除は承認フロー経由のみ）

#### `create_approval_request`
- 入力: `{ "action_type": str, "resource_id": str, "description": str, "risk_level": str }`
- 処理:
  - `bmao-approval-requests` DynamoDBに承認リクエスト登録
  - `request_id` = UUID生成
  - `ttl` = 現在時刻 + 24時間
  - Chatworkに承認リクエスト通知送信
  - 日本語コメント: 「破壊的操作の前に必ず人間承認を要求する安全設計の中核機能」
- 出力: `{"request_id": str, "status": "pending_approval"}`

#### `check_approval_status`
- 入力: `{ "request_id": str }`
- 処理:
  - `bmao-approval-requests` から該当レコード取得
  - ステータス（pending/approved/rejected/expired）を返す
- 出力: `{"request_id": str, "status": str, "approved_by": str (optional)}`

#### `execute_ssm_document`
- 入力: `{ "instance_id": str, "document_name": str, "parameters": dict, "request_id": str }`
- 処理:
  - `check_approval_status` で承認確認（未承認なら実行拒否）
  - SSM `send_command` でドキュメント実行
  - 実行結果をDynamoDB `bmao-execution-history` に記録
  - 日本語コメント: 「承認済みリクエストのみSSMコマンド実行。request_idで承認状態を二重確認」
- 出力: `{"command_id": str, "status": str}`

---

### 4. lambda/reporter/ の実装

**ファイル**: `lambda/reporter/handler.py`

#### `generate_html_report`
- 入力: `{ "execution_id": str, "title": str, "findings": list, "recommendations": list }`
- 処理:
  - HTML形式のレポート生成（CSSスタイル込み）
  - S3 `bmao-reports-{account_id}` にアップロード
  - Presigned URL（有効期限7日）を生成
  - 日本語コメント: 「Agent実行結果を人間が読みやすいHTMLレポートに変換。Presigned URLで安全に共有」
- 出力: `{"s3_key": str, "presigned_url": str}`

#### `send_chatwork_notification`
- 入力: `{ "message": str, "report_url": str (optional) }`
- 処理:
  - SSMから `room_id` と `api_token` を取得
  - Chatwork API POST: `application/x-www-form-urlencoded`
  - ヘッダー: `X-ChatWorkToken: {api_token}`
  - エンドポイント: `https://api.chatwork.com/v2/rooms/{room_id}/messages`
  - 日本語コメント: 「全エージェント実行結果の最終通知先。Slackではなく必ずChatworkに送信すること」
- 出力: `{"message_id": str, "status": "sent"}`

---

### 5. terraform/modules/lambda/ の実装

各Lambda関数のTerraformリソースを実装:

- `aws_lambda_function` × 4（incident_investigator / cost_optimizer / remediation / reporter）
- `aws_lambda_function_url` は作成しない（Bedrock Agent経由のみ呼び出し）
- 各LambdaのIAMロール（base roleを継承しつつ個別権限追加）:

  **incident_investigator追加権限**:
  - `cloudwatch:DescribeAlarms`
  - `cloudwatch:GetMetricStatistics`
  - `xray:GetServiceGraph`
  - `xray:GetTraceSummaries`
  - `config:GetComplianceSummaryByConfigRule`

  **cost_optimizer追加権限**:
  - `ce:GetAnomalies`
  - `ce:GetRightsizingRecommendation`
  - `ec2:DescribeVolumes`
  - `ec2:DescribeAddresses`

  **remediation追加権限**:
  - `dynamodb:PutItem`, `GetItem`, `UpdateItem` on `bmao-approval-requests`
  - `ssm:SendCommand`
  - `ssm:GetCommandInvocation`
  - **禁止**: `ec2:TerminateInstances`, `rds:DeleteDBInstance`, `iam:*`

  **reporter追加権限**:
  - `s3:PutObject` on `bmao-reports-*`
  - `s3:GeneratePresignedUrl`（IAM不要、SDK側で生成）

- Bedrock Agentからの呼び出し許可:
  ```hcl
  # Bedrock AgentがLambdaを呼び出せるようにResource-based policyを追加
  resource "aws_lambda_permission" "bedrock_agent" {
    statement_id  = "AllowBedrockAgent"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.xxx.function_name
    principal     = "bedrock.amazonaws.com"
  }
  ```

---

### 6. terraform/modules/agents/ の実装

#### Bedrock Guardrails
```hcl
resource "aws_bedrock_guardrail" "ops_guardrail" {
  name        = "${local.prefix}-ops-guardrail"
  description = "運用エージェントの破壊的操作を制限するガードレール"

  # 禁止トピック
  topic_policy_config {
    topics_config {
      name       = "destructive-operations"
      definition = "EC2インスタンスの削除、RDSインスタンスの削除、S3バケットの削除、IAMロールの削除など、本番環境への破壊的操作"
      examples   = ["delete instance", "terminate EC2", "drop database", "remove IAM role"]
      type       = "DENY"
    }
  }
}
```

#### Sub-agent 3種のBedrock Agent定義
各Agentに以下を定義:
- `aws_bedrock_agent`
- `aws_bedrock_agent_action_group`（対応するLambdaとOpenAPI仕様を紐付け）
- `aws_bedrock_agent_alias`（`TSTALIASID` を使わず独自エイリアス）

**Incident Investigator Agentのinstruction例**:
```
あなたはAWSインフラの障害調査専門エージェントです。
Supervisor Agentから調査タスクを受け取ったら、以下の順序で調査を実行してください:

1. CloudWatchアラームの状態を確認する
2. X-Rayトレースでエラー伝播経路を特定する
3. AWS Configで直近の設定変更を確認する
4. 調査結果を構造化JSONで返す

調査結果には必ず以下を含めること:
- 障害が発生しているリソース
- 推定される根本原因
- 影響範囲
- 推奨アクション（実行はしない、提案のみ）
```

**Cost Optimizer Agentのinstruction例**:
```
あなたはAWSコスト最適化専門エージェントです。
コスト異常や最適化機会を分析し、削減施策を提案します。

重要: コスト削減のための実際のリソース操作は行いません。
発見事項と推奨アクションをSupervisor Agentに返し、
実行はRemediationエージェントが承認フロー経由で行います。
```

**Remediation Agentのinstruction例**:
```
あなたはAWS運用の修復実行専門エージェントです。
Supervisor Agentから修復タスクを受け取った場合:

1. まず必ずcreate_approval_requestで承認リクエストを作成する
2. Chatwork通知が送信されたことを確認する
3. check_approval_statusで承認を確認する（未承認の場合は実行しない）
4. 承認済みの場合のみexecute_ssm_documentで実行する

絶対に承認なしで修復を実行してはいけません。
```

---

### 7. agents/*/openapi.yaml の作成

各Sub-agentのAction GroupをOpenAPI 3.0形式で定義。
例（incident_investigator/openapi.yaml の一部）:

```yaml
openapi: "3.0.0"
info:
  title: "Incident Investigator API"
  version: "1.0.0"
paths:
  /investigate_cloudwatch_alarms:
    post:
      operationId: investigateCloudwatchAlarms
      description: "CloudWatchアラームの状態と関連メトリクスを調査する"
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              properties:
                time_range_minutes:
                  type: integer
                  description: "調査対象の時間範囲（分）"
                  default: 60
```

---

## 完了条件

- [ ] Lambda 4種が `terraform validate` で通ること
- [ ] Bedrock Agent 3種が定義されていること
- [ ] Guardrailsが破壊的操作をDENYすること
- [ ] Remediationが必ず承認フローを経由することがコードで保証されていること
- [ ] 各OpenAPI仕様がBedrock Agent Action Groupの要件を満たすこと

---

## 次フェーズの予告

Phase 3では以下を実装する:
- Supervisor Agentの定義と委譲ロジック
- Step Functions ステートマシン（長時間オーケストレーション + タイムアウト制御）
- EventBridgeトリガー設定（Cost Anomaly / CloudWatch Alarm）
- Multi-Agent Collaborationの結合テスト