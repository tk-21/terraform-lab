# Phase 3 — Security Hub 有効化 + Custom Action 実装

## このフェーズの目的

AWS Security Hub を有効化し、Config Rulesの FindingsをSecurity Hubに集約する。
さらに Security Hub Custom Action を作成し、手動トリガーの修復フローを構築する。

## 前提確認

```bash
# Phase2のConfig Rulesが有効であること
aws configservice describe-config-rules \
  --query "ConfigRules[?contains(ConfigRuleName,'csar')].ConfigRuleName" \
  --output table

# Security Hubが有効でないこと (二重有効化エラー防止)
aws securityhub describe-hub 2>&1 || echo "未有効化 (正常)"
```

## 作成するリソース一覧

### 1. Security Hub 有効化

**ファイル**: `terraform/modules/security_hub/main.tf`

```hcl
# Security Hub 本体を有効化
resource "aws_securityhub_account" "main" {
  # auto_enable_controls: AWS標準セキュリティコントロールを自動有効化
  auto_enable_controls = true

  # control_finding_generator: SECURITY_CONTROL (新形式) を使用
  # 旧形式 STANDARD_CONTROL は廃止予定のため新形式を採用
  control_finding_generator = "SECURITY_CONTROL"

  # enable_default_standards: AWS基本セキュリティベストプラクティスを有効化
  enable_default_standards = true
}

# AWS基本セキュリティベストプラクティス標準を有効化
resource "aws_securityhub_standards_subscription" "aws_foundational" {
  standards_arn = "arn:aws:securityhub:ap-northeast-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

# CIS AWS Foundations Benchmark v1.4.0 を有効化
resource "aws_securityhub_standards_subscription" "cis_v140" {
  standards_arn = "arn:aws:securityhub:ap-northeast-1::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.main]
}
```

### 2. Config → Security Hub Finding 連携

**ファイル**: `terraform/modules/security_hub/config_integration.tf`

Security HubはConfig Rulesの結果を自動的にFindingsとして取り込む。
`aws_securityhub_account` 有効化後、Config Rulesの非準拠は自動的にFindingとなる。

以下のEventBridge Ruleで Security Hub Findingをキャッチする:

```hcl
# Security Hub Finding生成イベントをキャッチ (Config Rule由来)
resource "aws_cloudwatch_event_rule" "securityhub_finding" {
  name        = "csar-securityhub-finding-from-config"
  description = "Security HubのConfig Rule由来FindingをCloudWatch Logsへ記録"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
    detail = {
      findings = {
        ProductName    = ["Config"]          # Config由来のFindingのみ
        RecordState    = ["ACTIVE"]
        Workflow       = { Status = ["NEW"] }
        Compliance     = { Status = ["FAILED"] }
      }
    }
  })
}

# CloudWatch Logs グループへの記録 (Finding一覧の可視化用)
resource "aws_cloudwatch_log_group" "securityhub_findings" {
  name              = "/csar/securityhub/findings"
  retention_in_days = 90
}

resource "aws_cloudwatch_event_target" "securityhub_finding_logs" {
  rule      = aws_cloudwatch_event_rule.securityhub_finding.name
  target_id = "csar-finding-to-logs"
  arn       = aws_cloudwatch_log_group.securityhub_findings.arn
}
```

### 3. Security Hub Custom Action — 手動修復トリガー

Custom Actionは Security Hub のFinding一覧画面から「アクション」ボタンとして表示される。
Finding を選択して Custom Action をクリックすると EventBridge イベントが発行される。

**ファイル**: `terraform/modules/security_hub/custom_actions.tf`

```hcl
# S3修復用 Custom Action
resource "aws_securityhub_action_target" "s3_remediate" {
  name        = "CSAR: S3自動修復"
  identifier  = "CSARRemediateS3"   # 英数字のみ、20文字以内
  description = "S3バケットのPublic Access/暗号化違反を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# IAM修復用 Custom Action
resource "aws_securityhub_action_target" "iam_remediate" {
  name        = "CSAR: IAM自動修復"
  identifier  = "CSARRemediateIAM"
  description = "IAMユーザーのMFA未設定/過剰権限違反を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# EC2/SG修復用 Custom Action
resource "aws_securityhub_action_target" "sg_remediate" {
  name        = "CSAR: SG自動修復"
  identifier  = "CSARRemediateSG"
  description = "Security GroupのSSH/RDP 0.0.0.0/0開放を手動トリガーで修復する"

  depends_on = [aws_securityhub_account.main]
}

# RDS修復用 Custom Action
resource "aws_securityhub_action_target" "rds_remediate" {
  name        = "CSAR: RDS修復通知"
  identifier  = "CSARRemediateRDS"
  description = "RDSの暗号化/Public Access違反を検知して手動対応を通知する"

  depends_on = [aws_securityhub_account.main]
}
```

### 4. Custom Action → Lambda ルーティング (EventBridge)

**ファイル**: `terraform/modules/security_hub/custom_action_routes.tf`

Custom Actionがクリックされると以下のイベントが発行される:
```json
{
  "source": "aws.securityhub",
  "detail-type": "Security Hub Findings - Custom Action",
  "detail": {
    "actionName": "CSAR: S3自動修復",
    "actionDescription": "...",
    "findings": [ { ... Finding詳細 ... } ]
  }
}
```

```hcl
# S3 Custom Action → Lambda
resource "aws_cloudwatch_event_rule" "s3_custom_action" {
  name        = "csar-securityhub-custom-action-s3"
  description = "Security Hub Custom Action: S3修復"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.s3_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "s3_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.s3_custom_action.name
  target_id = "csar-s3-custom-action-lambda"
  arn       = var.s3_remediation_lambda_arn  # Phase4で設定

  # Custom Actionの場合もDLQ設定
  dead_letter_config {
    arn = var.dlq_arn
  }
}

# IAM Custom Action → Lambda
resource "aws_cloudwatch_event_rule" "iam_custom_action" {
  name        = "csar-securityhub-custom-action-iam"
  description = "Security Hub Custom Action: IAM修復"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.iam_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "iam_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.iam_custom_action.name
  target_id = "csar-iam-custom-action-lambda"
  arn       = var.iam_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# SG Custom Action → Lambda
resource "aws_cloudwatch_event_rule" "sg_custom_action" {
  name        = "csar-securityhub-custom-action-sg"
  description = "Security Hub Custom Action: SG修復"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.sg_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "sg_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.sg_custom_action.name
  target_id = "csar-sg-custom-action-lambda"
  arn       = var.sg_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}

# RDS Custom Action → Lambda
resource "aws_cloudwatch_event_rule" "rds_custom_action" {
  name        = "csar-securityhub-custom-action-rds"
  description = "Security Hub Custom Action: RDS修復通知"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.rds_remediate.arn]
  })
}

resource "aws_cloudwatch_event_target" "rds_custom_action_lambda" {
  rule      = aws_cloudwatch_event_rule.rds_custom_action.name
  target_id = "csar-rds-custom-action-lambda"
  arn       = var.rds_remediation_lambda_arn

  dead_letter_config {
    arn = var.dlq_arn
  }
}
```

### 5. Lambda の Event Source 判別ロジック (設計メモ)

LambdaはConfig RuleトリガーとCustom Actionトリガーの両方を受け取る。
イベントの `detail-type` で判別する:

```python
def detect_trigger_source(event: dict) -> str:
    """イベントのトリガー元を判定する"""
    detail_type = event.get("detail-type", "")

    if detail_type == "Config Rules Compliance Change":
        # Config Rule自動検知トリガー
        return "CONFIG_RULE"
    elif detail_type == "Security Hub Findings - Custom Action":
        # Security Hub Custom Actionによる手動トリガー
        return "SECURITY_HUB_CUSTOM_ACTION"
    else:
        raise ValueError(f"未知のトリガー種別: {detail_type}")
```

Config Ruleトリガー時のeventから取得する情報:
```python
# Config Ruleトリガー時
config_rule_name = event["detail"]["configRuleName"]
resource_id = event["detail"]["resourceId"]
resource_type = event["detail"]["resourceType"]  # "AWS::S3::Bucket" 等
```

Custom Actionトリガー時のeventから取得する情報:
```python
# Security Hub Custom Actionトリガー時
findings = event["detail"]["findings"]
finding = findings[0]  # 複数選択時も最初の1件を処理（設計上の単純化）
resource_id = finding["Resources"][0]["Id"]
resource_type = finding["Resources"][0]["Type"]  # "AwsS3Bucket" 等 (形式が異なる!)
```

**重要**: Config RuleのresourceTypeとSecurity HubのresourceTypeは形式が異なる。
変換テーブルをLambda内に持つ。

### 6. ファイル構成

```
terraform/modules/security_hub/
├── main.tf                    # Security Hub有効化 + Standards
├── config_integration.tf      # Config → Security Hub連携 + Findings記録
├── custom_actions.tf          # Custom Action 4種定義
├── custom_action_routes.tf    # Custom Action → Lambda EventBridge Route
├── variables.tf
└── outputs.tf

docs/adr/
└── ADR-003-securityhub-integration.md  # テンプレートのみ生成
```

`docs/adr/ADR-003-securityhub-integration.md`:
```markdown
# ADR-003: Security Hub Custom Action の採用理由

## ステータス
決定済み

## コンテキスト
Config Rulesによる自動修復ループに加え、
セキュリティ担当者が「このFindingを今すぐ修復したい」と判断した場合の
手動トリガー修復フローが必要だった。

## 検討した選択肢
- Security Hub Custom Action (EventBridge経由でLambdaを直接起動)
- AWS Systems Manager Quick Setup
- Config Remediation (SSM Automation Runbook)
- AWS Lambda を直接マネジメントコンソールから手動実行

## 決定
Security Hub Custom Action を採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - なぜSecurity Hubのコンソールから直接修復操作できることがセキュリティ担当者にとって価値があるか
  - Config RuleトリガーとCustom Actionトリガーで同じLambdaを再利用できる利点
  - IAMコンソールやEC2コンソールに移動する必要がない運用上のメリット
-->

## 結果として生じるトレードオフ
- Security Hubの有効化コストが発生 (月$0.001/リソース記録)
- Findingのresource_type形式がConfig Ruleと異なるため変換ロジックが必要
```

## 実行手順

```bash
cd terraform/environments/dev

# main.tfにmodule "security_hub"を追加してapply
terraform plan -out=tfplan
terraform apply tfplan
```

## 完了確認

```bash
# Security Hub が有効であること
aws securityhub describe-hub \
  --query "{HubArn:HubArn,AutoEnableControls:AutoEnableControls}"

# Standards サブスクリプション確認
aws securityhub get-enabled-standards \
  --query "StandardsSubscriptions[].{Arn:StandardsArn,Status:StandardsStatus}"

# Custom Actions が存在すること (4件)
aws securityhub describe-action-targets \
  --query "ActionTargets[].{Name:Name,Id:ActionTargetArn}"

# Security Hub Findingsが蓄積されているか確認
aws securityhub get-findings \
  --filters '{"RecordState":[{"Value":"ACTIVE","Comparison":"EQUALS"}]}' \
  --max-results 5 \
  --query "Findings[].{Title:Title,Severity:Severity.Label,Resource:Resources[0].Id}"

# EventBridge Custom Action Rulesの確認
aws events list-rules \
  --name-prefix "csar-securityhub-custom-action" \
  --query "Rules[].{Name:Name,State:State}"
```

## 口頭説明チェック (Phase 3)

以下を見ずに説明できるか確認すること:

1. **Security HubとConfig Rulesの役割分担** — Config Rulesが「違反を検知する」のに対して、Security Hubは何をする役割か？なぜ両方必要なのか？

2. **Custom Actionの動作フロー** — マネジメントコンソールで「Finding選択 → Custom Actionクリック」からLambda実行までの処理の流れを順番に説明できるか？

3. **Config Rule Finding と Security Hub Finding の resource_type の形式差異** — `AWS::S3::Bucket` と `AwsS3Bucket` の違いをなぜ意識する必要があるか？Lambda内でどう対処するか？

4. **Security Hub Standards (CIS / AWS Foundational) の意味** — これらを有効化すると何が自動的に評価されるようになるか？Config Rulesとの重複はあるか？

5. **Custom ActionのARNをEventBridgeのresourcesフィルタに使う理由** — `detail-type` だけでフィルタしないのはなぜか？複数のCustom Actionを区別するには何が必要か？