# ✅Phase 4 — 検証スクリプト + ADR + Runbook + README

## 前フェーズ（Phase 1-3）の成果物

Phase 1: VPC / SG Terraform モジュール
Phase 2: ALB / ASG (Target Tracking CPU 70%) Terraform モジュール
Phase 3: IAM ロール / FIS 実験テンプレート Terraform モジュール
         - FIS テンプレート ID: `terraform output fis_experiment_template_id` で取得
         - ASG 名: `terraform output asg_name` で取得
         - ALB DNS: `terraform output alb_dns_name` で取得

## このフェーズのゴール

以下のファイルを生成する:
1. `scripts/run_experiment.sh` — FIS 実験起動 + 結果サマリー
2. `scripts/check_scaling.sh` — ASG スケールアウト監視
3. `docs/adrs/001-use-fis-over-thirdparty.md`
4. `docs/adrs/002-asg-target-tracking.md`
5. `runbooks/cpu-stress-experiment.md`
6. `README.md`

---

## 生成指示

### 1. `scripts/run_experiment.sh`

```bash
#!/usr/bin/env bash
# FIS CPU ストレス実験の起動・監視・結果サマリースクリプト
# 使い方: ./scripts/run_experiment.sh [--dry-run]
#
# 前提: AWS CLI が設定済み、jq がインストール済み
# リージョン: ap-northeast-1

set -euo pipefail

# ============================
# 設定値（terraform output から取得）
# ============================
REGION="ap-northeast-1"
# 実行前に terraform output で確認し、ここに設定する
TEMPLATE_ID="${FIS_TEMPLATE_ID:-}" # 環境変数か直接指定
ASG_NAME="${ASG_NAME:-}"
ALB_DNS="${ALB_DNS:-}"

# バリデーション
if [[ -z "$TEMPLATE_ID" || -z "$ASG_NAME" || -z "$ALB_DNS" ]]; then
  echo "[ERROR] 環境変数が未設定です"
  echo "  export FIS_TEMPLATE_ID=\$(cd terraform/environments/dev && terraform output -raw fis_experiment_template_id)"
  echo "  export ASG_NAME=\$(cd terraform/environments/dev && terraform output -raw asg_name)"
  echo "  export ALB_DNS=\$(cd terraform/environments/dev && terraform output -raw alb_dns_name)"
  exit 1
fi

DRY_RUN="${1:-}"

echo "================================================"
echo " カオスエンジニアリング実験: CPU ストレス"
echo " テンプレート ID: $TEMPLATE_ID"
echo " 対象 ASG: $ASG_NAME"
echo "================================================"

# ドライランモード
if [[ "$DRY_RUN" == "--dry-run" ]]; then
  echo "[DRY RUN] 実験は起動しません。設定確認のみ。"
  exit 0
fi

# 実験前の ASG インスタンス数を記録
PRE_COUNT=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances | length(@)' \
  --output text)
echo "[INFO] 実験前インスタンス数: $PRE_COUNT"

# FIS 実験を起動
echo "[INFO] FIS 実験を起動中..."
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "$TEMPLATE_ID" \
  --region "$REGION" \
  --query 'experiment.id' \
  --output text)
echo "[INFO] 実験 ID: $EXPERIMENT_ID"

# 実験完了まで待機（最大 15 分）
MAX_WAIT=900
ELAPSED=0
INTERVAL=30

echo "[INFO] 実験の完了を待機中..."
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(aws fis get-experiment \
    --id "$EXPERIMENT_ID" \
    --region "$REGION" \
    --query 'experiment.state.status' \
    --output text)

  echo "[INFO] $(date '+%H:%M:%S') 実験ステータス: $STATUS (経過: ${ELAPSED}秒)"

  if [[ "$STATUS" == "completed" || "$STATUS" == "stopped" || "$STATUS" == "failed" ]]; then
    break
  fi

  sleep $INTERVAL
  ELAPSED=$((ELAPSED + INTERVAL))
done

# 実験後のインスタンス数を確認
POST_COUNT=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0].Instances | length(@)' \
  --output text)

# 結果サマリー
echo ""
echo "================================================"
echo " 実験結果サマリー"
echo "================================================"
echo " 実験 ID    : $EXPERIMENT_ID"
echo " 最終ステータス: $STATUS"
echo " 実験前インスタンス数: $PRE_COUNT"
echo " 実験後インスタンス数: $POST_COUNT"

if [[ $POST_COUNT -gt $PRE_COUNT ]]; then
  echo " ✅ スケールアウト成功！($PRE_COUNT → $POST_COUNT インスタンス)"
else
  echo " ⚠️  スケールアウトが確認できませんでした（$PRE_COUNT → $POST_COUNT）"
  echo "     CloudWatch メトリクスと FIS ログを確認してください"
fi

echo ""
echo " FIS ログ: CloudWatch Logs /aws/fis/cel-dev-cpu-stress"
echo " ALB エンドポイント: http://$ALB_DNS/health"
echo "================================================"
```

---

### 2. `scripts/check_scaling.sh`

```bash
#!/usr/bin/env bash
# ASG スケールアウト状態をリアルタイム監視するスクリプト
# 使い方: ./scripts/check_scaling.sh [監視間隔秒数(デフォルト30)]
#
# watch コマンドと組み合わせて使う:
#   watch -n 30 ./scripts/check_scaling.sh

set -euo pipefail

REGION="ap-northeast-1"
ASG_NAME="${ASG_NAME:-}"
INTERVAL="${1:-30}"

if [[ -z "$ASG_NAME" ]]; then
  echo "[ERROR] ASG_NAME 環境変数を設定してください"
  exit 1
fi

echo "=== ASG スケーリング状態: $(date '+%Y-%m-%d %H:%M:%S') ==="
echo ""

# ASG の現在状態
ASG_INFO=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --region "$REGION" \
  --query 'AutoScalingGroups[0]')

DESIRED=$(echo "$ASG_INFO" | jq -r '.DesiredCapacity')
MIN=$(echo "$ASG_INFO" | jq -r '.MinSize')
MAX=$(echo "$ASG_INFO" | jq -r '.MaxSize')
INSTANCES=$(echo "$ASG_INFO" | jq -r '.Instances | length')

echo "  最小/希望/最大: $MIN / $DESIRED / $MAX"
echo "  実際のインスタンス数: $INSTANCES"
echo ""

# 各インスタンスの状態
echo "  インスタンス詳細:"
echo "$ASG_INFO" | jq -r '.Instances[] | "  - \(.InstanceId) | \(.LifecycleState) | \(.HealthStatus)"'

# 直近のスケーリングアクティビティ（5件）
echo ""
echo "  直近のスケーリングアクティビティ:"
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG_NAME" \
  --max-records 5 \
  --region "$REGION" \
  --query 'Activities[*].{Time:StartTime,Status:StatusCode,Cause:Cause}' \
  --output table
```

---

### 3. `docs/adrs/001-use-fis-over-thirdparty.md`

以下の内容で ADR を生成:

- **ステータス**: Accepted
- **コンテキスト**: カオスエンジニアリングツール選定（FIS vs Chaos Monkey vs Gremlin）
- **決定**: AWS FIS を採用
- **理由**:
  - AWS ネイティブサービスのためクロスアカウント IAM・VPC 設定が不要
  - Terraform `aws_fis_experiment_template` で完全 IaC 化可能（ポートフォリオ訴求点）
  - `AWSFIS-Run-CPU-Stress` など AWS 提供マネージドドキュメントで即時利用可能
  - 停止条件（CloudWatch アラーム）と IAM による多層安全弁が標準機能
  - 追加コストなし（EC2/SSM の使用コストのみ）
- **トレードオフ**: Gremlin のような高度なシナリオ（ネットワーク遅延の細かな制御等）は不可

---

### 4. `docs/adrs/002-asg-target-tracking.md`

以下の内容で ADR を生成:

- **ステータス**: Accepted
- **コンテキスト**: ASG スケーリングポリシーの種類選定
- **決定**: Target Tracking Scaling（CPU 70%）を採用
- **理由**:
  - FIS で CPU に負荷を注入するため、CPU ベースのポリシーが実験と直接対応
  - シンプルステップスケーリングより AWS が自動でスケールイン/アウトを計算
  - FIS 停止後の CPU 低下でスケールインも自動検証できる
- **トレードオフ**: スケジュールスケーリングや SQS キュー深度ベースの複合ポリシーは別シナリオで検討

---

### 5. `runbooks/cpu-stress-experiment.md`

以下のセクションを含む Runbook を生成:

```markdown
# Runbook: CPU ストレス実験手順

## 概要
## 前提条件（AWS CLI / jq / terraform インストール済み等）
## 実験前チェックリスト（ASG ヘルシー確認 / アラーム状態確認）
## 実験手順（ステップバイステップ）
  Step 1: Terraform 出力値の確認
  Step 2: 環境変数のエクスポート
  Step 3: ドライラン確認
  Step 4: 実験起動
  Step 5: スケールアウト監視（check_scaling.sh 実行）
  Step 6: FIS ログ確認（CloudWatch Logs）
  Step 7: 実験後の状態確認
## ロールバック手順（手動でのスケールイン）
## トラブルシューティング
  - FIS が FAILED になる場合
  - スケールアウトしない場合
  - SSM SendCommand が失敗する場合
## コスト影響（実験 1 回あたりの概算）
```

---

### 6. `README.md`

以下の構成で README を生成（ポートフォリオ向け、英語サマリー + 日本語詳細）:

```markdown
# chaos-engineering-lab 🔥

## 概要（日本語 + English サマリー）
AWS FIS × Terraform で実現するカオスエンジニアリング基盤。
CPU ストレス注入 → ASG スケールアウトの自動検証パイプライン。

## アーキテクチャ図（Mermaid）
Internet → ALB → TG → ASG(EC2 × 2-6)
FIS → SSM SendCommand → EC2(stress-ng)
CloudWatch Alarm → FIS 停止条件

## ポートフォリオポイント（箇条書き）

## ディレクトリ構造

## セットアップ手順
  1. バックエンド S3/DynamoDB の事前作成
  2. terraform.tfvars の account_id 設定
  3. フェーズ別 terraform apply 手順

## 実験実行手順（run_experiment.sh）

## コスト見積もり

## 安全設計（多層安全弁の説明）

## 今後の拡張予定
  - ネットワーク遅延シナリオ（aws:network:latency）
  - RDS フェイルオーバーシナリオ
  - GitHub Actions CI での実験自動実行
```

---

## 完了条件

- [ ] `run_experiment.sh` が実行権限付きで生成されること（chmod +x）
- [ ] `check_scaling.sh` が実行権限付きで生成されること
- [ ] 両スクリプトに `set -euo pipefail` が含まれること
- [ ] ADR が 2 件生成されること
- [ ] Runbook にトラブルシューティングセクションが含まれること
- [ ] README に Mermaid アーキテクチャ図が含まれること
- [ ] README にポートフォリオポイントが明記されていること

---

## 全フェーズ完了後の最終チェックリスト

```bash
# 全ファイルの存在確認
find . -name "*.tf" | sort
find . -name "*.sh" | sort
find . -name "*.md" | sort

# Terraform 検証
cd terraform/environments/dev
terraform fmt -recursive -check ../../..
terraform validate

# スクリプトに実行権限付与
chmod +x scripts/*.sh
```

---

## ポートフォリオ公開準備（Zenn / GitHub）

README に以下を追記:
- `terraform output` の出力例（ダミー値で）
- FIS 実験ダッシュボードのスクリーンショット配置場所（`docs/screenshots/`）
- バッジ: Terraform / AWS FIS / License