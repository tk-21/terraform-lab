# ✅Phase 6 — ADR作成・口頭説明チェック・クリーンアップ

## 目標
- Architecture Decision Record（ADR）を3本書く
- 「なぜこの設計にしたか」を自分の言葉で説明できる状態にする
- リソースクリーンアップスクリプトを作成する

---

## 重要な約束
ADRの「決定の根拠」「検討した代替案」「結果と振り返り」セクションは**AI生成禁止**。
自分の言葉で書くこと。テンプレートと問いかけは提供するが、中身は自分で埋めること。

---

## タスク一覧

### 6-1. ADR-001: なぜStep Functionsを使ったか

`docs/adr/001-use-step-functions.md` を作成する（テンプレート）:

```markdown
# ADR-001: ワークフローオーケストレーターにStep Functionsを採用

## ステータス
Accepted

## コンテキスト
ECS前処理 → Bedrock推論 → Chatwork通知という複数ステップの処理を
つなぐ仕組みが必要だった。選択肢として以下を検討した:
- Lambda連鎖（前のLambdaが次のLambdaを直接呼び出す）
- SQS + Lambda（キュー経由の非同期連携）
- Step Functions（ステートマシンによるオーケストレーション）

## 決定
Step Functionsを採用する。

## 決定の根拠
<!-- ここは自分の言葉で書くこと（AI生成禁止） -->
<!-- 以下の問いへの回答を含めること: -->
<!-- - Lambda連鎖と比べてStep Functionsが優れている点は何か? -->
<!-- - ECSタスクの完了待機を自分で実装するとどうなるか? -->
<!-- - 実際に作ってみて「Step Functionsにして良かった」と感じた瞬間はあったか? -->

（ここに自分の言葉で記述する）

## 検討した代替案とその棄却理由
<!-- 自分の言葉で記述 -->

## 結果と振り返り
<!-- 実装後に感じたこと・気づきを自分の言葉で記述 -->
<!-- 面接で「なぜStep Functionsを選んだのか」と聞かれたとき、 -->
<!-- ここに書いたことを1分で話せるか確認すること -->
```

---

### 6-2. ADR-002: なぜNAT GatewayではなくVPC Endpointを使ったか

`docs/adr/002-vpc-endpoints-over-nat-gateway.md` を作成する（テンプレート）:

```markdown
# ADR-002: NAT GatewayではなくVPC Endpointを採用

## ステータス
Accepted

## コンテキスト
ECS FargateタスクおよびLambdaがECR、S3、Bedrock、DynamoDB等の
AWSサービスにアクセスする手段が必要だった。

## 決定
NAT Gatewayを使用せず、VPC Endpointのみでプライベート通信を実現する。

## 決定の根拠
<!-- 自分の言葉で記述（AI生成禁止） -->
<!-- 以下を含めること: -->
<!-- - NAT Gatewayのコストをざっくり計算してみた結果 -->
<!-- - Gateway型とInterface型を使い分けた判断基準 -->
<!-- - Bedrock用のInterface Endpointがなぜ必要か -->

（ここに自分の言葉で記述する）

## 検討した代替案とその棄却理由
<!-- 自分の言葉で記述 -->

## 結果と振り返り
<!-- 実装後に感じたこと・気づきを自分の言葉で記述 -->
```

---

### 6-3. ADR-003: BedrockモデルにClaude Haikuを選んだ理由

`docs/adr/003-bedrock-model-haiku.md` を作成する（テンプレート）:

```markdown
# ADR-003: BedrockモデルにClaude 3 Haikuを採用

## ステータス
Accepted

## コンテキスト
データ分析・要約タスクにBedrockを使用する際、複数のモデルから選択する必要があった:
- Claude 3 Opus
- Claude 3 Sonnet
- Claude 3 Haiku

## 決定
Claude 3 Haikuを採用し、モデルIDをIAMポリシーでHaikuのみに制限する。

## 決定の根拠
<!-- 自分の言葉で記述（AI生成禁止） -->
<!-- 以下を含めること: -->
<!-- - 実際にHaikuで推論した結果、品質は要件を満たせていたか? -->
<!-- - モデルIDをIAMで固定することで何が嬉しいか? -->
<!-- - 本番でSonnetに切り替える判断をするとしたら、どんな条件が満たされた時か? -->

（ここに自分の言葉で記述する）

## 検討した代替案とその棄却理由
<!-- 自分の言葉で記述 -->

## 結果と振り返り
<!-- 自分の言葉で記述 -->
```

---

### 6-4. README.md作成

`README.md` を作成する:

```markdown
# ai-inference-pipeline

S3トリガー → Step Functions → ECS Fargate（Docker前処理）→ Lambda × Bedrock → DynamoDB → Chatwork通知
のAI推論パイプライン。全リソースTerraform管理。

## アーキテクチャ

```
S3 (input/) 
  → EventBridge
  → Step Functions
      ├─ ECS Fargate (前処理コンテナ / Docker / arm64)
      ├─ Lambda (Bedrock Claude Haiku 推論)
      └─ Lambda (Chatwork通知)
  → DynamoDB (結果永続化)
```

## 技術スタック
- IaC: Terraform
- コンテナ: Docker (linux/arm64), Amazon ECS Fargate Spot
- AI: Amazon Bedrock (Claude 3 Haiku)
- ワークフロー: AWS Step Functions (STANDARD)
- Lambda: Python 3.12 / arm64 / Lambda Powertools
- DB: DynamoDB (PAY_PER_REQUEST)
- 通知: Chatwork
- VPC: NAT Gateway不使用・VPC Endpointのみ

## コスト設計
| 決定 | 理由 |
|---|---|
| NAT Gateway不使用 | ~$32/月を削減 |
| Fargate Spot優先 | ECSコストを最大70%削減 |
| arm64 (Graviton2) | x86_64比 約20%コスト削減 |
| DynamoDB PAY_PER_REQUEST | アクセス予測不能のためオンデマンド |
| Bedrock Haiku | Sonnetと比較して推論コスト約60%削減 |

## セットアップ

### 前提条件
- Terraform >= 1.6.0
- AWS CLI設定済み
- Docker buildx (arm64対応)

### デプロイ手順
```bash
# 1. tfvarsを編集
vim terraform/environments/dev/terraform.tfvars

# 2. フェーズごとに実行
claude < phase1.md  # 基盤インフラ
claude < phase2.md  # Docker + ECS
claude < phase3.md  # Lambda
claude < phase4.md  # Step Functions
claude < phase5.md  # EventBridge + E2Eテスト
```

## ADR一覧
- [001: Step Functions採用](docs/adr/001-use-step-functions.md)
- [002: VPC Endpoint採用](docs/adr/002-vpc-endpoints-over-nat-gateway.md)
- [003: Claude Haiku採用](docs/adr/003-bedrock-model-haiku.md)

## 計測値（実測）
| 指標 | 値 |
|---|---|
| E2E実行時間 | - |
| ECS前処理時間 | - |
| Bedrock推論レイテンシ | - |
```

---

### 6-5. クリーンアップスクリプト作成

`scripts/cleanup.sh`:

```bash
#!/bin/bash
# リソース全削除スクリプト（ハンズオン終了後のコスト削減用）
set -euo pipefail

echo "⚠️  全AWSリソースを削除します。5秒後に開始します..."
sleep 5

cd "$(dirname "$0")/../terraform/environments/dev"

# ECRのイメージを先に削除（Terraformのdestroy前に必要）
ECR_REPO=$(terraform output -raw ecr_repository_url 2>/dev/null | sed 's|.*/||')
if [ -n "$ECR_REPO" ]; then
  echo "ECRイメージを削除中..."
  aws ecr batch-delete-image \
    --repository-name "aip/dev/preprocessor" \
    --image-ids "$(aws ecr list-images --repository-name "aip/dev/preprocessor" \
      --query 'imageIds' --output json 2>/dev/null || echo '[]')" \
    --region ap-northeast-1 2>/dev/null || true
fi

# SSMパラメータ削除
echo "SSMパラメータを削除中..."
aws ssm delete-parameter --name "/aip/dev/chatwork/token" --region ap-northeast-1 2>/dev/null || true

# Terraform destroy
echo "Terraformリソースを削除中..."
terraform destroy -auto-approve

echo "✅ クリーンアップ完了"
```

```bash
chmod +x scripts/cleanup.sh
```

---

### 6-6. 最終確認コマンド

```bash
# 全フェーズの完了確認
echo "=== S3バケット ==="
aws s3 ls | grep aip-dev

echo "=== DynamoDB ==="
aws dynamodb list-tables --query 'TableNames[?contains(@, `aip-dev`)]'

echo "=== ECSクラスター ==="
aws ecs list-clusters --query 'clusterArns[?contains(@, `aip-dev`)]'

echo "=== Step Functions ==="
aws stepfunctions list-state-machines --query 'stateMachines[?contains(name, `aip-dev`)].name'

echo "=== Lambda ==="
aws lambda list-functions --query 'Functions[?contains(FunctionName, `aip-dev`)].FunctionName'

echo "=== ECR ==="
aws ecr describe-repositories --query 'repositories[?contains(repositoryName, `aip`)].repositoryName'
```

---

## 口頭説明 最終チェック（面接想定）

以下の質問に対して、メモなしで各1〜2分で答えられるか確認すること:

**設計判断について**
- 「このパイプラインでStep Functionsを使った理由を教えてください」
- 「NAT Gatewayを使わない設計にした理由は？実装上の工夫は？」
- 「BedrockのモデルをHaikuに固定した設計意図は？」

**技術的深掘り**
- 「ECSタスクロールとタスク実行ロールの違いを説明してください」
- 「EventBridgeとSNSを使い分ける判断基準は何ですか？」
- 「Step FunctionsのSTANDARD型を選んだ理由は？」

**トラブルシューティング**
- 「パイプラインが失敗したとき、どこから調べますか？」
- 「Bedrockのスロットリングが発生した場合、どう対処しますか？」

**コスト・運用**
- 「このシステムの月額コスト見積もりを概算できますか？」
- 「本番化する際に追加すべき要素は何ですか？」

---

## 完了チェックリスト

- [ ] ADR 3本を自分の言葉で記述完了
- [ ] README.mdに計測値を記入済み
- [ ] 口頭説明チェックの全問に答えられる
- [ ] GitHubにpushしてポートフォリオとして公開可能な状態
- [ ] cleanup.shが動作する（必要なら実行してコスト削減）