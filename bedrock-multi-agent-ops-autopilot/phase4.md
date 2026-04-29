# ✅Phase 4: デプロイ・動作確認・GitHub公開準備

## Phase 1-3で作成したもの（サマリー）

**Phase 1（基盤）**: S3/DynamoDB/SSM/IAM/CloudWatch Logs

**Phase 2（Sub-agents）**:
- Lambda × 4: incident-investigator / cost-optimizer / remediation / reporter
- Bedrock Agent × 3（Sub-agents）: 各エージェントのAliasあり
- Bedrock Guardrails: 破壊的操作をDENY

**Phase 3（Supervisor + 統合）**:
- Supervisor Agent: `anthropic.claude-3-7-sonnet-20250219-v1:0` / Multi-Agent Collaborationモード
- Step Functions: EventBridge → Supervisor Agent呼び出しのオーケストレーター
- EventBridge: Cost Anomaly / CloudWatch Alarm → Step Functions起動
- Cost Anomaly Detection Monitor: サービス単位で$50以上の異常を検知

---

## このフェーズで作成・実施するもの

デプロイ、動作確認、GitHub公開用ドキュメントの整備を行い、ポートフォリオとして公開できる状態にする。

---

## タスク一覧

### 1. デプロイ前チェックリストの確認

以下を順番に実行してエラーがないことを確認:

```bash
# Terraform検証
cd terraform
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var="environment=dev" -out=tfplan

# Lambda依存関係の確認
cd ../lambda/incident_investigator && pip install -r requirements.txt -t ./package --dry-run
cd ../cost_optimizer && pip install -r requirements.txt -t ./package --dry-run
cd ../remediation && pip install -r requirements.txt -t ./package --dry-run
cd ../reporter && pip install -r requirements.txt -t ./package --dry-run
```

### 2. Terraform Apply（段階的実行）

以下の順序でモジュールを個別にApply（依存関係の問題を早期検出）:

```bash
# Step 1: foundation
terraform apply -target=module.foundation -var="environment=dev"

# Step 2: lambda
terraform apply -target=module.lambda -var="environment=dev"

# Step 3: agents（Sub-agents）
terraform apply -target=module.agents -var="environment=dev"

# Step 4: stepfunctions
terraform apply -target=module.stepfunctions -var="environment=dev"

# Step 5: 残りすべて
terraform apply -var="environment=dev"
```

Apply後に以下を確認するスクリプト `scripts/verify_deploy.sh` を作成:

```bash
#!/bin/bash
set -e

PREFIX="bmao"
REGION="ap-northeast-1"

echo "=== デプロイ確認スクリプト ==="

# Lambda関数の存在確認
for fn in incident-investigator cost-optimizer remediation reporter; do
  STATUS=$(aws lambda get-function --function-name "${PREFIX}-${fn}" \
    --region $REGION --query 'Configuration.State' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "Lambda ${PREFIX}-${fn}: ${STATUS}"
done

# Bedrock Agent確認
echo "Bedrock Agents:"
aws bedrock-agent list-agents --region $REGION \
  --query 'agentSummaries[?contains(agentName, `bmao`)].{Name:agentName,Status:agentStatus}' \
  --output table

# DynamoDBテーブル確認
for tbl in execution-history approval-requests; do
  STATUS=$(aws dynamodb describe-table --table-name "${PREFIX}-${tbl}" \
    --region $REGION --query 'Table.TableStatus' --output text 2>/dev/null || echo "NOT_FOUND")
  echo "DynamoDB ${PREFIX}-${tbl}: ${STATUS}"
done

# Step Functions確認
SFN_ARN=$(aws stepfunctions list-state-machines --region $REGION \
  --query "stateMachines[?contains(name, '${PREFIX}')].stateMachineArn" \
  --output text)
echo "Step Functions: ${SFN_ARN}"

echo "=== 確認完了 ==="
```

### 3. SSMパラメータの設定

デプロイ後、Chatwork接続のためのSSMパラメータを実際の値に更新:

```bash
# Chatwork Room IDを設定
aws ssm put-parameter \
  --name "/bmao/chatwork/room_id" \
  --value "YOUR_ROOM_ID" \
  --type "SecureString" \
  --overwrite \
  --region ap-northeast-1

# Chatwork API Tokenを設定
aws ssm put-parameter \
  --name "/bmao/chatwork/api_token" \
  --value "YOUR_API_TOKEN" \
  --type "SecureString" \
  --overwrite \
  --region ap-northeast-1
```

### 4. 動作テスト

#### テスト1: Reporter Lambda単体テスト
```bash
aws lambda invoke \
  --function-name bmao-reporter \
  --region ap-northeast-1 \
  --payload '{"action": "send_chatwork_notification", "message": "🤖 Multi-Agent Ops Autopilot: デプロイ確認テスト"}' \
  --cli-binary-format raw-in-base64-out \
  response.json
cat response.json
```

#### テスト2: Step Functions手動実行（コスト異常シミュレーション）
```bash
EXECUTION_NAME="manual-test-$(date +%Y%m%d%H%M%S)"
SFN_ARN=$(terraform output -raw state_machine_arn)

aws stepfunctions start-execution \
  --state-machine-arn $SFN_ARN \
  --name $EXECUTION_NAME \
  --input '{
    "event_type": "COST_ANOMALY",
    "event_detail": {
      "anomaly_id": "test-001",
      "total_impact_usd": "55.00",
      "service": "Amazon EC2"
    }
  }' \
  --region ap-northeast-1

echo "実行名: $EXECUTION_NAME"
echo "Step Functions Consoleで確認してください"
```

#### テスト3: 実行結果確認スクリプト `scripts/check_execution.sh`
```bash
#!/bin/bash
EXECUTION_NAME=$1
REGION="ap-northeast-1"

# DynamoDB確認
aws dynamodb get-item \
  --table-name bmao-execution-history \
  --key "{\"execution_id\": {\"S\": \"${EXECUTION_NAME}\"}}" \
  --region $REGION \
  --output table

# S3レポート確認
aws s3 ls s3://bmao-reports-$(aws sts get-caller-identity --query Account --output text)/ \
  --region $REGION
```

### 5. README.md の作成（GitHub公開用）

以下の構成でルートの `README.md` を作成:

```markdown
# 🤖 Bedrock Multi-Agent Ops Autopilot

> AWS運用タスク（障害対応・コスト最適化）をBedrock Multi-Agent Collaborationで自律実行するシステム

## アーキテクチャ

[Mermaid図を埋め込む]

## 技術スタック

| カテゴリ | 技術 |
|---|---|
| AI/LLM | Amazon Bedrock (Claude 3.7 Sonnet / Claude 3.5 Haiku) |
| オーケストレーション | AWS Step Functions |
| イベント駆動 | Amazon EventBridge |
| サーバーレス | AWS Lambda (Python 3.12, arm64) |
| データストア | Amazon DynamoDB |
| IaC | Terraform >= 1.7 |
| 通知 | Chatwork API |

## 主な特徴

- **Multi-Agent Collaboration**: Supervisor AgentがSub-agentに専門タスクを委譲
- **Human-in-the-loop**: 破壊的操作は必ず人間承認フローを経由
- **Bedrock Guardrails**: EC2削除・RDS削除など危険操作をシステムレベルでブロック
- **コスト最適化**: Sub-agentにClaude 3.5 Haikuを使用（月額$15以下）

## セットアップ

[デプロイ手順]

## ディレクトリ構造

[tree出力]

## 設計の考え方

[ADRへのリンク]
```

### 6. Zenn記事の下書き作成

**ファイル**: `docs/zenn-article-draft.md`

以下の構成で技術記事の下書きを作成:

```
タイトル: Amazon Bedrockのマルチエージェント機能でAWS運用を自律化した話

## はじめに
なぜマルチエージェントが必要か（単一エージェントの限界）

## アーキテクチャ設計
Supervisor + Sub-agentパターンの選択理由

## 実装のポイント

### 1. Supervisor AgentによるSub-agent委譲
aws_bedrock_agent_collaboratorリソースの使い方

### 2. Human-in-the-loop設計
承認フローの実装（DynamoDB + Chatwork通知）

### 3. Bedrock Guardrailsで安全を担保
破壊的操作のブロック設定

### 4. Step FunctionsとBedrockの統合
arn:aws:states:::bedrock:invokeAgentのThrottling対策

## コスト設計
月額$15以下に抑えるための工夫
（Supervisorのみ Sonnet、Sub-agentはHaiku）

## ハマったポイントと解決策

## まとめ・今後の展望
```

### 7. .github/workflows/ci.yml の作成（OIDC認証）

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

permissions:
  id-token: write
  contents: read

jobs:
  terraform-validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Terraform Init
        run: cd terraform && terraform init -backend=false

      - name: Terraform Validate
        run: cd terraform && terraform validate

      - name: Terraform Format Check
        run: cd terraform && terraform fmt -check -recursive

  python-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Install dependencies
        run: pip install ruff boto3 aws-lambda-powertools

      - name: Lint with ruff
        run: ruff check lambda/
```

---

## 完了条件

- [ ] `terraform apply` でエラーなくデプロイ完了
- [ ] `scripts/verify_deploy.sh` の全項目がOK
- [ ] Step Functions手動テストがSUCCEEDEDで完了
- [ ] DynamoDBに実行履歴が記録されていること
- [ ] Chatworkに通知が届いていること
- [ ] S3にHTMLレポートが生成されていること
- [ ] README.mdが公開レベルのクオリティで完成
- [ ] GitHub ActionsのCIがパスすること

---

## プロジェクト完了後の展開

1. **GitHubに公開**: `bedrock-multi-agent-ops-autopilot` リポジトリ
2. **Zenn記事公開**: マルチエージェント実装の解説記事
3. **次のプロジェクト候補**:
   - MLOps（SageMaker Pipelines）
   - BackstageカスタムPlugin開発