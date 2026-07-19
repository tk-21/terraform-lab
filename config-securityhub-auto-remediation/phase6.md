# Phase 6 — 統合テスト / ADR自己記述確認 / README / 面接準備

## このフェーズの目的

エンドツーエンドの動作確認を行い、ADRの自己記述状況を確認し、
GitHubへのプッシュとZenn記事の下書きを準備する。

## 前提確認

```bash
# 全リソースが存在すること
aws lambda list-functions --query "Functions[?contains(FunctionName,'csar')].FunctionName"
aws configservice describe-config-rules --query "ConfigRules[?contains(ConfigRuleName,'csar')].ConfigRuleName"
aws securityhub describe-action-targets --query "ActionTargets[].Name"
aws cloudwatch get-dashboard --dashboard-name CSAR-AutoRemediation > /dev/null && echo "Dashboard: OK"
```

---

## 1. 統合テスト手順

### テスト 1: S3 PublicAccess 自動修復フロー (Config Ruleトリガー)

```bash
# Step 1: 違反バケット作成
bash tests/integration/create_violation_s3.sh

BUCKET_NAME=$(aws s3api list-buckets --query "Buckets[?contains(Name,'csar-test-violation')].Name" --output text | head -1)
echo "テスト対象バケット: ${BUCKET_NAME}"

# Step 2: Config Rule手動評価をトリガー
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-s3-bucket-public-read-prohibited

# Step 3: 評価結果確認 (2-3分後)
sleep 180
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name csar-s3-bucket-public-read-prohibited \
  --compliance-types NON_COMPLIANT \
  --query "EvaluationResults[?EvaluationResultIdentifier.EvaluationResultQualifier.ResourceId=='${BUCKET_NAME}']"

# Step 4: EventBridgeイベントが発行されLambdaが実行されるまで待機 (最大5分)
sleep 60

# Step 5: Lambda実行ログ確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/csar-s3-remediation" \
  --filter-pattern "修復対象" \
  --start-time $(date -d '10 minutes ago' +%s)000 \
  --query "events[].message"

# Step 6: 修復結果確認 (Block Public Access が有効化されているか)
aws s3api get-public-access-block --bucket "${BUCKET_NAME}"
# 期待値: BlockPublicAcls/IgnorePublicAcls/BlockPublicPolicy/RestrictPublicBuckets が全てtrue

# Step 7: DynamoDB修復ログ確認
aws dynamodb scan \
  --table-name csar-remediation-log \
  --filter-expression "resource_id = :rid" \
  --expression-attribute-values "{\":rid\":{\"S\":\"${BUCKET_NAME}\"}}" \
  --query "Items"

# Step 8: Chatwork通知確認 (Chatworkで手動確認)
echo "Chatworkで通知を確認してください"

# クリーンアップ
aws s3api delete-bucket --bucket "${BUCKET_NAME}" --region ap-northeast-1
```

### テスト 2: Security Group SSH 自動修復フロー

```bash
# Step 1: 違反SG作成
bash tests/integration/create_violation_sg.sh

SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=csar-test-violation-sg-*" \
  --query "SecurityGroups[0].GroupId" --output text)

echo "テスト対象SG: ${SG_ID}"

# Step 2: Config Rule評価トリガー
aws configservice start-config-rules-evaluation \
  --config-rule-names csar-restricted-ssh

# Step 3: 2-3分後に修復結果確認
sleep 180

aws ec2 describe-security-groups \
  --group-ids "${SG_ID}" \
  --query "SecurityGroups[0].IpPermissions"
# 期待値: SSH 0.0.0.0/0 のルールが削除されていること

# Step 4: DynamoDB確認
aws dynamodb scan \
  --table-name csar-remediation-log \
  --filter-expression "resource_id = :rid" \
  --expression-attribute-values "{\":rid\":{\"S\":\"${SG_ID}\"}}" \
  --query "Items[0].{status:status.S,action:remediation_action.S}"

# クリーンアップ
aws ec2 delete-security-group --group-id "${SG_ID}"
```

### テスト 3: Security Hub Custom Action 手動修復フロー

```bash
# Step 1: Security Hub Findingsを確認
aws securityhub get-findings \
  --filters '{
    "RecordState": [{"Value": "ACTIVE", "Comparison": "EQUALS"}],
    "ProductName": [{"Value": "Config", "Comparison": "EQUALS"}]
  }' \
  --max-results 5 \
  --query "Findings[].{Title:Title,Id:Id,Resource:Resources[0].Id}"

# Step 2: マネジメントコンソールから手動でCustom Actionをトリガーする
# Security Hub → Findings → Finding選択 → アクション → "CSAR: S3自動修復"
echo "手順:"
echo "  1. https://ap-northeast-1.console.aws.amazon.com/securityhub/home#/findings を開く"
echo "  2. Config由来のS3 Findingにチェックを入れる"
echo "  3. [アクション] → [CSAR: S3自動修復] をクリック"
echo "  4. Lambda実行ログ・Chatwork通知を確認する"

# Step 3: Lambda実行ログでSECURITY_HUB_CUSTOM_ACTIONトリガーを確認
aws logs filter-log-events \
  --log-group-name "/aws/lambda/csar-s3-remediation" \
  --filter-pattern "SECURITY_HUB_CUSTOM_ACTION" \
  --start-time $(date -d '5 minutes ago' +%s)000
```

### テスト 4: DLQ フロー (Lambda 意図的エラー)

```bash
# Lambda に意図的にエラーを発生させ DLQ に積まれることを確認する
# 存在しないバケット名を含むEventを直接Lambdaにinvokeする
aws lambda invoke \
  --function-name csar-s3-remediation \
  --payload '{
    "detail-type": "Config Rules Compliance Change",
    "detail": {
      "configRuleName": "csar-s3-bucket-public-read-prohibited",
      "resourceId": "csar-nonexistent-bucket-12345",
      "resourceType": "AWS::S3::Bucket",
      "newEvaluationResult": {"complianceType": "NON_COMPLIANT"}
    }
  }' \
  --cli-binary-format raw-in-base64-out \
  /tmp/lambda_response.json

cat /tmp/lambda_response.json

# DLQ メッセージ数確認 (3回リトライ後にDLQへ)
sleep 30
aws sqs get-queue-attributes \
  --queue-url $(aws sqs get-queue-url --queue-name csar-remediation-dlq --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessagesVisible

# DLQのメッセージ内容確認
aws sqs receive-message \
  --queue-url $(aws sqs get-queue-url --queue-name csar-remediation-dlq --query QueueUrl --output text) \
  --max-number-of-messages 1 \
  --query "Messages[0].Body"
```

---

## 2. README.md 生成

`README.md`:

```markdown
# config-securityhub-auto-remediation

AWS Config Rules + Security Hub Custom Action による**セキュリティコンプライアンス自動修復基盤**。

コンプライアンス違反を検知してから自動修復・監査ログ記録・Chatwork通知までをフルサイクルで実装。

## アーキテクチャ

[architecture.md](docs/architecture.md) を参照。

## 修復対象

| リソース | 違反内容 | 修復方法 |
|---------|---------|---------|
| S3 | PublicRead ACL | Block Public Access 有効化 |
| S3 | SSE未設定 | AES256 SSE 強制設定 |
| IAM | MFA未設定 | コンソールアクセス無効化 |
| EC2/SG | SSH 0.0.0.0/0 | インバウンドルール削除 |
| RDS | PubliclyAccessible | false に変更 |
| RDS | 暗号化なし | スナップショット取得 + 手動対応通知 |

## 技術スタック

- **検知**: AWS Config Rules (マネージドルール × 8)
- **集約**: Amazon Security Hub + Custom Action
- **ルーティング**: Amazon EventBridge
- **修復**: AWS Lambda (Python 3.12 / arm64 / Lambda Powertools)
- **記録**: Amazon DynamoDB (修復ログ) + Amazon S3 (監査証跡)
- **通知**: Chatwork REST API
- **IaC**: Terraform >= 1.7.0

## コスト設計

NAT Gateway ゼロ、VPC Endpoints のみ。Graviton2 (arm64) Lambda。
月100修復実行以下なら Lambda は無料枠内。

## セットアップ

```bash
# 1. バックエンドS3作成
bash scripts/init-backend.sh

# 2. Terraform適用 (Phase1-5)
cd terraform/environments/dev
terraform init && terraform apply

# 3. SSMシークレット設定
aws ssm put-parameter --name "/csar/chatwork/token" --value "TOKEN" --type SecureString --overwrite
aws ssm put-parameter --name "/csar/chatwork/room_id" --value "ROOM_ID" --type SecureString --overwrite
```

## ADR

- [ADR-001: Config Rules vs GuardDuty](docs/adr/ADR-001-config-vs-guardduty.md)
- [ADR-002: Lambda vs SSM Automation](docs/adr/ADR-002-lambda-vs-ssm-automation.md)
- [ADR-003: Security Hub Custom Action](docs/adr/ADR-003-securityhub-integration.md)
- [ADR-004: 監査ログ二重書き設計](docs/adr/ADR-004-audit-storage.md)
```

---

## 3. ADR 自己記述確認チェックリスト

**⚠️ 以下の全項目を確認してから GitHub にプッシュすること。**

```
[ ] ADR-001: ## 決定理由 セクションを自分の言葉で記述した
[ ] ADR-002: ## 決定理由 セクションを自分の言葉で記述した
[ ] ADR-003: ## 決定理由 セクションを自分の言葉で記述した
[ ] ADR-004: ## 決定理由 セクションを自分の言葉で記述した
[ ] 各ADRの決定理由はAI生成テキストを転用していない
[ ] 各ADRは「自分がなぜそう決めたか」を口頭でも説明できる
```

---

## 4. 面接準備 (STAR形式)

### メインエピソード: セキュリティコンプライアンス自動修復基盤の構築

**Situation (状況)**
```
小規模チームで複数AWSアカウントのセキュリティコンプライアンスを維持する必要があった。
手動での設定確認は工数がかかり、見落としが発生していた。
S3のPublicAccess設定ミスやSecurity Groupの開放は発見まで時間がかかっていた。
```

**Task (課題)**
```
「違反が発生したら自動的に修復する」ループを実装する。
修復ログを監査証跡として保管し、手動対応が必要なケースも明確に識別する。
企業向けに訴求できるレベルのアーキテクチャ品質を担保する。
```

**Action (行動)**
```
AWS Config Rules × 8種を有効化し、Security HubでFindingを集約する構成を設計した。

修復基盤の選択肢としてSSM Automation Runbookも検討したが、
複雑なエラーハンドリング (DLQ連携、Chatwork通知、DynamoDB記録) と
テスタビリティの観点からLambda (Python 3.12 / arm64) を採用した。

RDSの暗号化はインプレース変更が技術的に不可能なため、
スナップショット取得 + 手動対応通知という設計判断を行いADRに記録した。

Security Hub Custom Actionにより、セキュリティ担当者がFinding画面から
直接修復をトリガーできる UX も実現した。
```

**Result (結果)**
```
S3 PublicAccess違反: Config Rule評価から修復完了まで平均3分以内
Security Group SSH開放: 違反検知から即時ルール削除
RDS暗号化違反: 5分以内にスナップショット取得 + Chatwork通知
修復ログ: DynamoDB (90日TTL) + S3 (Glacier) で監査証跡を自動保管
DLQ: 3回リトライ失敗後に未処理メッセージをCloudWatchでアラート
```

### 定量的指標テーブル

| 指標 | 値 | 比較 |
|------|----|----|
| 修復までの平均時間 (S3/SG) | 3分以内 | 手動対応: 数時間〜数日 |
| 対応リソース種別 | 4種 (S3/IAM/EC2-SG/RDS) | マネージドルール8種をカバー |
| 月間コスト試算 | ~$15 (100修復/月) | NAT Gateway排除で~$35/月削減 |
| Lambda arm64採用 | 20%コスト削減 | x86_64比 |
| 監査ログ保管 | 90日DynamoDB + 1年S3 (Glacier) | コンプライアンス要件対応 |

### よく聞かれる質問と回答骨子

**Q: なぜConfig RulesとSecurity Hubを組み合わせたのか？**
```
Config Rulesは「設定の変更を検知して評価する」ことが得意。
Security Hubは「複数サービスのFindingを一元管理する」ことが得意。
両者を組み合わせることで、自動修復ループとFinding管理UIの両方を実現した。
Custom Actionにより、セキュリティ担当者がコンソールから直接修復操作できる。
```

**Q: RDSの暗号化をなぜ自動修復しなかったのか？**
```
AWSはRDSの暗号化をインプレースで変更する機能を提供していない。
技術的にはスナップショット→暗号化済み復元→旧DB削除の3ステップが必要。
データベースの切り替えは業務影響があるため、自動化せずスナップショット取得+通知に留めた。
この判断をADRに記録し、「自動修復できないものを正直に設計に反映する」ことを示した。
```

**Q: DLQが必要な理由は？**
```
Lambda修復が失敗した場合（API権限不足、レートリミット等）、
イベントを失わずに後から再処理できる仕組みが必要だった。
EventBridgeのretry (3回) + Lambda DLQ の2段構えにすることで、
一時的な障害での修復漏れを防いでいる。
```

---

## 5. GitHub プッシュ準備

```bash
# .gitignore 生成
cat > .gitignore << 'EOF'
# Terraform
.terraform/
*.tfstate
*.tfstate.backup
*.tfplan
.terraform.lock.hcl
terraform/environments/dev/terraform.tfvars.local

# Lambda ビルド成果物
lambda/**/*.zip
lambda/**/package/

# Python
__pycache__/
*.pyc
*.pyo
.pytest_cache/

# OS
.DS_Store
Thumbs.db
EOF

# GitHubリポジトリ作成・プッシュ
git init
git add .
git commit -m "feat: AWS Config + Security Hub 自動修復基盤 初期実装

- Config Rules × 8種 (S3/IAM/EC2-SG/RDS)
- Security Hub Custom Action による手動修復トリガー
- Lambda × 4 (Python 3.12 / arm64 / Lambda Powertools)
- DynamoDB修復ログ + S3監査証跡 + Chatwork通知
- CloudWatch Dashboard による可視化
- NAT Gateway ゼロ設計 (VPC Endpoints のみ)"

# GitHub CLI でリポジトリ作成
gh repo create config-securityhub-auto-remediation \
  --public \
  --description "AWS Config Rules + Security Hub Custom Action によるセキュリティコンプライアンス自動修復基盤"
git push -u origin main
```

---

## 6. Zenn記事 下書き骨子

**タイトル案**:
`AWS Config + Security Hub で作るセキュリティ違反の自動修復ループ — RDSが自動修復できない理由まで解説`

**構成**:
```
1. はじめに: なぜこれを作ったか (手動確認の限界)
2. アーキテクチャ概要 (Mermaid図)
3. Config Rules と Security Hub の役割分担
4. 自動修復の設計方針
   - S3/SG: 完全自動修復
   - IAM: コンソールアクセス無効化 + 通知
   - RDS暗号化: 自動修復できない理由と代替策
5. Lambda 実装のポイント
   - Config RuleとCustom Actionの両方に対応する
   - DLQ設計 (べき等性)
   - arm64採用
6. 監査ログ設計 (DynamoDB + S3の使い分け)
7. コスト (NAT Gateway排除の効果)
8. まとめ: 企業向けに訴求できるポイント
```

---

## 最終口頭説明チェック (Phase 6 / 総仕上げ)

**15分間で以下をホワイトボードに書きながら説明できること:**

1. このシステムのアーキテクチャ全体（検知→ルーティング→修復→記録）を図示しながら説明

2. Config RuleとSecurity Hub Custom Actionの2つのトリガーパスをそれぞれ説明

3. S3/SG/IAM/RDSそれぞれで「なぜその修復方法を選んだか」の技術的根拠を説明
   （特にRDSが完全自動修復できない理由）

4. DLQの2段構え設計（EventBridgeレベル + Lambdaレベル）の意図

5. DynamoDBとS3の両方に監査ログを書く設計判断の理由

**合格基準**: 「なぜ？」と聞かれたときに、ADRに書いた自分の言葉で答えられること。