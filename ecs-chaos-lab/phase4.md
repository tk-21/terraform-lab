# ✅Phase 4 — 検証スクリプト + ADR × 3 + Runbook × 3 + README

## 前フェーズ（Phase 1-3）の成果物

Phase 1: VPC / SG / ECR / ALB（ネットワーク基盤）
Phase 2: IAM / ECS Cluster(ecl-dev-cluster) / Service(desired=2, awsvpc) / CW アラーム×2
Phase 3:
  - FIS テンプレート × 3（task-kill / network-disruption / desired-zero）
  - Lambda: ecl-desired-count-changer（シナリオ3用、arm64）
  - FIS ログ: /aws/fis/ecl-dev

terraform output で取得する値（スクリプト内で環境変数として使用）:
  - SCENARIO1_TEMPLATE_ID, SCENARIO2_TEMPLATE_ID, SCENARIO3_TEMPLATE_ID
  - CLUSTER_NAME = ecl-dev-cluster
  - SERVICE_NAME = ecl-dev-service
  - ALB_DNS（動作確認用）
  - LAMBDA_FUNCTION_NAME = ecl-desired-count-changer

## このフェーズのゴール

生成するファイル:
1. `scripts/run_task_kill.sh`
2. `scripts/run_network_disruption.sh`
3. `scripts/run_desired_zero.sh`
4. `scripts/watch_service.sh`
5. `docs/adrs/001-fargate-over-ec2.md`
6. `docs/adrs/002-three-scenario-design.md`
7. `docs/adrs/003-network-disruption-mechanism.md`
8. `runbooks/scenario1-task-kill.md`
9. `runbooks/scenario2-network-disruption.md`
10. `runbooks/scenario3-desired-zero.md`
11. `README.md`

---

## 生成指示

### 1. `scripts/run_task_kill.sh`（シナリオ1）

```bash
#!/usr/bin/env bash
# シナリオ1: ECS Task 強制停止 → Service 自己回復確認
# 使い方: ./scripts/run_task_kill.sh [--dry-run]
# 前提: AWS CLI / jq インストール済み、環境変数設定済み

set -euo pipefail

REGION="ap-northeast-1"
TEMPLATE_ID="${SCENARIO1_TEMPLATE_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
ALB_DNS="${ALB_DNS:-}"

# 環境変数未設定時の自動取得（terraform output から）
if [[ -z "$TEMPLATE_ID" ]]; then
  echo "[INFO] SCENARIO1_TEMPLATE_ID が未設定のため terraform output から取得します"
  TEMPLATE_ID=$(cd terraform/environments/dev && terraform output -raw scenario1_template_id)
fi

if [[ -z "$ALB_DNS" ]]; then
  ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
fi

DRY_RUN="${1:-}"

echo "========================================"
echo " シナリオ1: ECS Task 強制停止"
echo " テンプレート: $TEMPLATE_ID"
echo " クラスター: $CLUSTER_NAME / $SERVICE_NAME"
echo "========================================"

[[ "$DRY_RUN" == "--dry-run" ]] && echo "[DRY RUN] 終了" && exit 0

# 実験前の状態を記録
PRE_RUNNING=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
  --region "$REGION" \
  --query 'services[0].runningCount' --output text)
echo "[INFO] 実験前 RunningCount: $PRE_RUNNING"

# FIS 実験開始
echo "[INFO] FIS 実験を起動..."
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id "$TEMPLATE_ID" \
  --region "$REGION" \
  --query 'experiment.id' --output text)
echo "[INFO] 実験 ID: $EXPERIMENT_ID"

# 実験完了を待機（最大 10 分）
MAX_WAIT=600; ELAPSED=0; INTERVAL=20
while [[ $ELAPSED -lt $MAX_WAIT ]]; do
  STATUS=$(aws fis get-experiment --id "$EXPERIMENT_ID" \
    --region "$REGION" \
    --query 'experiment.state.status' --output text)

  RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' --output text)

  echo "[$(date '+%H:%M:%S')] FIS: $STATUS | RunningCount: $RUNNING"

  [[ "$STATUS" =~ ^(completed|stopped|failed)$ ]] && break
  sleep $INTERVAL; ELAPSED=$((ELAPSED + INTERVAL))
done

# 実験後の状態確認（復旧まで最大 3 分待機）
echo "[INFO] Service 復旧を待機中（最大 3 分）..."
RECOVERY_ELAPSED=0
while [[ $RECOVERY_ELAPSED -lt 180 ]]; do
  POST_RUNNING=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0].runningCount' --output text)
  [[ "$POST_RUNNING" -ge 2 ]] && break
  sleep 15; RECOVERY_ELAPSED=$((RECOVERY_ELAPSED + 15))
  echo "[$(date '+%H:%M:%S')] 復旧待機中... RunningCount: $POST_RUNNING"
done

echo ""
echo "========================================"
echo " 実験結果サマリー"
echo "========================================"
echo " 実験 ID: $EXPERIMENT_ID"
echo " 最終ステータス: $STATUS"
echo " 実験前 RunningCount: $PRE_RUNNING"
echo " 実験後 RunningCount: $POST_RUNNING"
echo " 復旧時間: 約 ${RECOVERY_ELAPSED} 秒"
echo ""
if [[ "${POST_RUNNING:-0}" -ge 2 ]]; then
  echo " ✅ 合格: Service が $RECOVERY_ELAPSED 秒以内に RunningCount=2 に復旧"
else
  echo " ❌ 要確認: RunningCount が 2 に戻りませんでした"
  echo "    ECS Events: aws ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME"
fi
echo " ALB: http://$ALB_DNS/health"
echo " FIS ログ: CloudWatch Logs /aws/fis/ecl-dev"
echo "========================================"
```

### 2. `scripts/run_network_disruption.sh`（シナリオ2）

シナリオ1と同じ構造で生成。以下の差分を反映:

- ヘッダーを「シナリオ2: ネットワーク遮断」に変更
- TEMPLATE_ID = SCENARIO2_TEMPLATE_ID
- 実験中は `curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS/health` で ALB レスポンスコードを監視
- 合否判定: FIS 実験中に HTTP 503 が発生し、実験終了後に 200 に復帰したことを確認
- 実験終了後の確認:
  ```bash
  # ALB が Healthy に戻るまで最大 2 分待機
  for i in $(seq 1 8); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://$ALB_DNS/health")
    echo "[$(date '+%H:%M:%S')] HTTP: $CODE"
    [[ "$CODE" == "200" ]] && echo "✅ 復旧確認" && break
    sleep 15
  done
  ```

### 3. `scripts/run_desired_zero.sh`（シナリオ3）

以下の構成で生成:

```bash
#!/usr/bin/env bash
# シナリオ3: ECS DesiredCount=0 → 全 Task 停止 → 手動復旧確認
# 使い方:
#   ./scripts/run_desired_zero.sh set_zero   # 全 Task 停止
#   ./scripts/run_desired_zero.sh restore    # Service 復旧
# 注意: FIS 実験（desired-zero テンプレート）の起動と、Lambda 直接起動の両方に対応

set -euo pipefail

REGION="ap-northeast-1"
TEMPLATE_ID="${SCENARIO3_TEMPLATE_ID:-}"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
LAMBDA_NAME="${LAMBDA_FUNCTION_NAME:-ecl-desired-count-changer}"
ACTION="${1:-set_zero}"  # set_zero | restore

case "$ACTION" in
  "set_zero")
    echo "[INFO] FIS 実験開始: DesiredCount を 0 に変更..."
    # FIS テンプレート経由で Lambda を起動（実験ログを FIS に記録）
    EXPERIMENT_ID=$(aws fis start-experiment \
      --experiment-template-id "$TEMPLATE_ID" \
      --region "$REGION" \
      --query 'experiment.id' --output text)
    echo "[INFO] 実験 ID: $EXPERIMENT_ID"
    echo "[INFO] ECS Service を監視: ./scripts/watch_service.sh"
    echo "[INFO] 復旧するには: $0 restore"
    ;;

  "restore")
    echo "[INFO] Lambda を直接起動して DesiredCount を 2 に復元..."
    # FIS 実験外で Lambda を直接起動（復旧操作）
    aws lambda invoke \
      --function-name "$LAMBDA_NAME" \
      --payload "$(echo '{"action":"restore"}' | base64)" \
      --cli-binary-format raw-in-base64-out \
      --region "$REGION" \
      /tmp/lambda_response.json
    cat /tmp/lambda_response.json | jq .

    # Service 安定化を待機
    echo "[INFO] Service の安定化を待機中..."
    aws ecs wait services-stable \
      --cluster "$CLUSTER_NAME" \
      --services "$SERVICE_NAME" \
      --region "$REGION"
    echo "[SUCCESS] ✅ Service が stable 状態に復旧しました"
    ;;

  *)
    echo "[ERROR] 不明なアクション: $ACTION (set_zero | restore)"
    exit 1
    ;;
esac
```

### 4. `scripts/watch_service.sh`

```bash
#!/usr/bin/env bash
# ECS Service 状態をリアルタイム監視（全シナリオ共通）
# 使い方: ./scripts/watch_service.sh
# 別ターミナルで実行し、実験スクリプトと並行して状態確認する

set -euo pipefail

REGION="ap-northeast-1"
CLUSTER_NAME="${CLUSTER_NAME:-ecl-dev-cluster}"
SERVICE_NAME="${SERVICE_NAME:-ecl-dev-service}"
ALB_DNS="${ALB_DNS:-}"

while true; do
  clear
  echo "=== ECS Service 監視: $(date '+%Y-%m-%d %H:%M:%S') ==="
  echo ""

  SVC=$(aws ecs describe-services \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$REGION" \
    --query 'services[0]')

  DESIRED=$(echo "$SVC" | jq -r '.desiredCount')
  RUNNING=$(echo "$SVC" | jq -r '.runningCount')
  PENDING=$(echo "$SVC" | jq -r '.pendingCount')

  echo "  DesiredCount : $DESIRED"
  echo "  RunningCount : $RUNNING"
  echo "  PendingCount : $PENDING"
  echo ""

  if [[ -n "$ALB_DNS" ]]; then
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 "http://$ALB_DNS/health" || echo "ERR")
    echo "  ALB /health  : HTTP $HTTP_CODE"
    echo ""
  fi

  echo "  直近のイベント（上位5件）:"
  echo "$SVC" | jq -r '.events[:5][] | "  [\(.createdAt | split(".")[0])] \(.message)"'

  sleep 10
done
```

---

### 5. ADR × 3

#### `docs/adrs/001-fargate-over-ec2.md`

```markdown
# ADR-001: ECS 起動タイプに Fargate を採用

## ステータス: Accepted

## コンテキスト
カオスエンジニアリング検証環境の ECS 起動タイプを選定する。
候補: Fargate / EC2 起動タイプ

## 決定
Fargate を採用する。

## 理由
- EC2 インスタンスの管理（パッチ・スケーリング）が不要でポートフォリオ実装に集中できる
- awsvpc ネットワークモードが標準のため、FIS `aws:ecs:task-network-blackhole-port` が使用可能
- Task ごとに ENI が割り当てられ、FIS のネットワーク遮断がタスクレベルで精密に動作する
- コスト: 使用時間のみ課金（検証後に Task 数 = 0 にすれば EC2 費用ゼロ）

## トレードオフ
- SSM Session Manager 経由のコンテナ接続は `ecs execute-command` が必要
- Fargate での FIS CPU ストレス注入は `aws:ecs:task-cpu-stress` アクション（実験的）
- EC2 起動タイプより若干コストが高い（0.25 vCPU の場合は誤差範囲）
```

#### `docs/adrs/002-three-scenario-design.md`

以下の内容で生成:
- **ステータス**: Accepted
- **コンテキスト**: FIS で検証する ECS 障害シナリオの選定
- **決定**: Task Kill / Network Disruption / Desired Count 0 の 3 シナリオ
- **理由**: 3 種類が「プロセス障害」「ネットワーク障害」「意図的スケールダウン」をそれぞれ代表する。異なる障害モードを組み合わせることで ECS Service の回復性を多角的に検証できる
- **各シナリオの観測ポイント**:
  - S1: ECS Service Controller の自動 Task 再起動速度
  - S2: ALB ヘルスチェックと Unhealthy Target の切り離し速度
  - S3: DesiredCount 操作による意図的なゼロスケールと復旧の手順確認

#### `docs/adrs/003-network-disruption-mechanism.md`

以下の内容で生成:
- **ステータス**: Accepted
- **コンテキスト**: `aws:ecs:task-network-blackhole-port` の動作原理の理解
- **決定と背景**:
  - Fargate Task は awsvpc モードで ENI を持つ
  - FIS はこの ENI に一時的なネットワーク ACL ルールを追加して指定ポートをブラックホール化
  - EC2 の `aws:network:disrupt-connectivity` とは異なる実装（EC2 側の NIC を操作）
  - FIS 終了後は自動的にルールが削除され通信が復旧する
- **注意事項**: PERCENT(50) 未満に設定しないと ALB が全 Unhealthy になりサービス断になる

---

### 6. Runbook × 3

#### `runbooks/scenario1-task-kill.md`

以下のセクションで生成:
1. 概要・目的・合格基準（RunningCount が 120 秒以内に 2 に復帰）
2. 前提条件（AWS CLI / jq / Service が stable 状態）
3. 実験前チェックリスト（RunningCount=2 / CW アラーム OK / ALB Healthy）
4. 実験手順（Step 1: 環境変数設定 → Step 2: watch_service.sh 起動 → Step 3: run_task_kill.sh 実行 → Step 4: 結果確認）
5. 合否判定基準と記録フォーマット
6. ロールバック（手動で `aws ecs update-service --desired-count 2`）
7. トラブルシューティング（Task が起動しない場合 / CloudWatch Events 確認方法）

#### `runbooks/scenario2-network-disruption.md`

以下のセクションで生成（シナリオ1と同構造）:
1. 概要・目的（ALB の Unhealthy 切り離し動作の確認）・合格基準（FIS 終了後 60 秒以内に HTTP 200 復旧）
2. 前提条件
3. 実験前チェックリスト（+ ALB HealthyHostCount の確認）
4. 実験手順（Step 1: 環境変数設定 → Step 2: watch_service.sh 起動 → Step 3: 別ターミナルで `watch curl http://$ALB_DNS/health` → Step 4: run_network_disruption.sh 実行）
5. 観測ポイント（FIS 中の HTTP 503 発生タイミング・ALB アクセスログ確認方法）
6. ロールバック（FIS 実験を手動停止 → `aws fis stop-experiment --id $EXPERIMENT_ID`）
7. トラブルシューティング（遮断されない場合 / HealthyHostCount 変化なし）

#### `runbooks/scenario3-desired-zero.md`

以下のセクションで生成:
1. 概要・目的（意図的ゼロスケール → 復旧手順の確立）・合格基準（restore 後 180 秒以内に RunningCount=2）
2. 前提条件（Lambda がデプロイ済み / FIS テンプレート ID 確認）
3. 実験手順:
   - Step 1: `run_desired_zero.sh set_zero` で全 Task 停止
   - Step 2: `watch_service.sh` で RunningCount=0 を確認
   - Step 3: ALB が 503 を返すことを確認（`curl -I http://$ALB_DNS/health`）
   - Step 4: （復旧）`run_desired_zero.sh restore` で DesiredCount=2 に復元
   - Step 5: Service stable 確認
4. `lifecycle { ignore_changes = [desired_count] }` がない場合の注意（次の `terraform apply` で desired_count が上書きされる）
5. トラブルシューティング（Lambda invoke 失敗 / Service が stable にならない場合）

---

### 7. `README.md`

以下の構成で生成:

```markdown
# ecs-chaos-lab 💥

> AWS FIS × ECS Fargate による3シナリオカオスエンジニアリング基盤

## Architecture

[Mermaid図を生成]
graph TD
  Internet --> ALB[ALB<br/>ecl-dev-alb]
  ALB --> TG[Target Group<br/>target_type=ip]
  TG --> S1[ECS Task 1<br/>Fargate / awsvpc]
  TG --> S2[ECS Task 2<br/>Fargate / awsvpc]
  S1 & S2 --> ECR[ECR<br/>ecl-dev-nginx]
  FIS[AWS FIS] -->|Scenario 1: task-kill| S1
  FIS -->|Scenario 2: network-blackhole| S1
  FIS -->|Scenario 3: lambda invoke| Lambda[Lambda<br/>desired-count-changer]
  Lambda -->|UpdateService| ECS[ECS Service<br/>ecl-dev-service]
  CW[CloudWatch Alarm] -->|Stop Condition| FIS

## Portfolio Highlights（ポートフォリオポイント）

- FIS ECS ネイティブアクション（task-kill / network-blackhole-port）の Terraform IaC 化
- awsvpc モードを活用したタスクレベルのネットワーク遮断実験
- Lambda を FIS アクションとして組み込んだカスタム障害注入（DesiredCount 操作）
- 多層安全弁: FIS 停止条件 × CloudWatch アラーム × IAM 最小権限 × PERCENT(50) 選択
- Container Insights による実験中のリアルタイムメトリクス可視化

## Scenarios

| # | シナリオ | FIS アクション | 観測ポイント |
|---|----------|----------------|-------------|
| 1 | Task 強制停止 | aws:ecs:task-kill | Service 自己回復速度 |
| 2 | ネットワーク遮断 | aws:ecs:task-network-blackhole-port | ALB Unhealthy 切り離し |
| 3 | DesiredCount=0 | aws:lambda:invoke | 手動復旧手順の確立 |

## Quick Start

[セットアップ → bootstrap.sh → terraform apply → 実験実行の手順]

## Cost

[月額コスト表]

## Safety Design

[多層安全弁の説明]
```

---

## 完了条件

- [ ] スクリプト 4 本が生成され chmod +x されていること
- [ ] 全スクリプトに `set -euo pipefail` が含まれること
- [ ] `watch_service.sh` が ECS Event を表示すること
- [ ] `run_desired_zero.sh` が `set_zero` / `restore` の両アクションに対応していること
- [ ] ADR が 3 件生成されること
- [ ] Runbook が 3 件生成され、それぞれに合格基準と復旧手順が含まれること
- [ ] README に Mermaid アーキテクチャ図が含まれること
- [ ] README にシナリオ比較表が含まれること

---

## 全フェーズ完了後の最終チェック

```bash
# ファイル存在確認
find . \( -name "*.tf" -o -name "*.sh" -o -name "*.md" -o -name "*.py" \) | sort

# Terraform 検証
cd terraform/environments/dev
terraform fmt -recursive -check ../../..
terraform validate

# スクリプト実行権限
chmod +x scripts/*.sh

# Lambda zip ビルドディレクトリ作成（.gitignore に追加）
mkdir -p terraform/modules/fis/.lambda_build
echo "terraform/modules/fis/.lambda_build/" >> .gitignore

# bootstrap（ECR イメージプッシュ）
./scripts/bootstrap.sh
```