# ✅Phase 6 — フェイルオーバー・ローテーション検証 + クリーンアップ

## 前フェーズ確認

```bash
ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
curl http://$ALB_DNS/health
# {"status": "healthy", "db": "connected"}
```

## このフェーズのゴール

- Aurora フェイルオーバー中の **アプリへの影響時間を計測** する
- Secrets Manager ローテーション中に **接続断がないことを証明** する
- 計測結果を面接で話せる Before/After メトリクスとして記録する
- 全リソースのクリーンアップ手順を確認する

---

## Step 6-1: フェイルオーバーテスト

### `scripts/failover-test.sh`

```bash
#!/bin/bash
# Aurora フェイルオーバー時のアプリ影響を計測する
# RDS Proxy なし vs あり の比較ができるようにエラー数を記録する
set -euo pipefail

ALB_DNS=${1:-""}
if [ -z "$ALB_DNS" ]; then
  ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
fi

echo "=== フェイルオーバーテスト開始 ==="
echo "ALB: http://$ALB_DNS"
echo ""

# バックグラウンドで継続的にリクエストを送る（2秒間隔）
RESULT_FILE="/tmp/failover-results-$(date +%s).txt"
SUCCESS=0
ERROR=0
TOTAL=0

monitor_requests() {
  while true; do
    START=$(date +%s%N)
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 \
      "http://$ALB_DNS/health" 2>/dev/null || echo "000")
    END=$(date +%s%N)
    LATENCY=$(( (END - START) / 1000000 ))

    TIMESTAMP=$(date '+%H:%M:%S')
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "[$TIMESTAMP] OK (${LATENCY}ms)" | tee -a "$RESULT_FILE"
      ((SUCCESS++)) || true
    else
      echo "[$TIMESTAMP] ERROR: HTTP $HTTP_STATUS (${LATENCY}ms)" | tee -a "$RESULT_FILE"
      ((ERROR++)) || true
    fi
    ((TOTAL++)) || true
    sleep 2
  done
}

# バックグラウンドでモニタリング開始
monitor_requests &
MONITOR_PID=$!

# 10秒待ってからフェイルオーバーを実施
sleep 10

echo ""
echo "=== Aurora フェイルオーバー実行 ==="
FAILOVER_START=$(date '+%H:%M:%S')
aws rds failover-db-cluster \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1
echo "フェイルオーバー開始: $FAILOVER_START"

# フェイルオーバー完了まで待つ（通常 20-40 秒）
echo "フェイルオーバー完了を待機中..."
aws rds wait db-cluster-available \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1
FAILOVER_END=$(date '+%H:%M:%S')
echo "フェイルオーバー完了: $FAILOVER_END"

# さらに 30 秒モニタリングを続ける
sleep 30

kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "=== テスト結果 ==="
echo "成功: $SUCCESS リクエスト"
echo "エラー: $ERROR リクエスト"
echo "合計: $TOTAL リクエスト"
echo "エラー率: $(echo "scale=1; $ERROR * 100 / $TOTAL" | bc)%"
echo "結果ファイル: $RESULT_FILE"
```

### フェイルオーバー実行

```bash
chmod +x scripts/failover-test.sh
bash scripts/failover-test.sh

# フェイルオーバー後に Writer/Reader が入れ替わっていることを確認
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=arpl-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,Role:ReadReplicaSourceDBInstanceIdentifier,AZ:AvailabilityZone,Status:DBInstanceStatus}' \
  --output table

# RDS Proxy がフェイルオーバー後も同じエンドポイントで接続できることを確認
curl http://$ALB_DNS/health
```

---

## Step 6-2: ローテーション中の接続断テスト

### `scripts/verify-rotation.sh`

```bash
#!/bin/bash
# Secrets Manager ローテーション中の接続断有無を計測
set -euo pipefail

ALB_DNS=${1:-$(cd terraform/environments/dev && terraform output -raw alb_dns_name)}
RESULT_FILE="/tmp/rotation-results-$(date +%s).txt"

echo "=== ローテーション検証開始 ==="
echo "監視対象: http://$ALB_DNS/items"
echo ""

SUCCESS=0
ERROR=0

# バックグラウンドでリクエスト監視
monitor() {
  while true; do
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      --max-time 5 "http://$ALB_DNS/items" 2>/dev/null || echo "000")
    TIMESTAMP=$(date '+%H:%M:%S')
    if [ "$HTTP_STATUS" = "200" ]; then
      echo "[$TIMESTAMP] OK" >> "$RESULT_FILE"
      ((SUCCESS++)) || true
    else
      echo "[$TIMESTAMP] ERROR: $HTTP_STATUS" >> "$RESULT_FILE"
      ((ERROR++)) || true
    fi
    sleep 2
  done
}

monitor &
MONITOR_PID=$!
sleep 5

echo "=== ローテーション実行 ==="
aws secretsmanager rotate-secret \
  --secret-id arpl/db/appuser \
  --rotate-immediately \
  --region ap-northeast-1
echo "ローテーション開始: $(date '+%H:%M:%S')"

# ローテーション完了を待機
while true; do
  STATUS=$(aws secretsmanager describe-secret \
    --secret-id arpl/db/appuser \
    --query 'RotationStatus' --output text 2>/dev/null || echo "UNKNOWN")
  if [ "$STATUS" != "InProgress" ]; then
    echo "ローテーション完了: $(date '+%H:%M:%S') (Status: $STATUS)"
    break
  fi
  echo "ローテーション中... $(date '+%H:%M:%S')"
  sleep 5
done

sleep 20
kill $MONITOR_PID 2>/dev/null || true

echo ""
echo "=== 検証結果 ==="
echo "成功: $SUCCESS"
echo "エラー: $ERROR"
if [ $ERROR -eq 0 ]; then
  echo "✅ ローテーション中に接続断なし（RDS Proxy が両パスワードを受け入れ）"
else
  echo "⚠️  エラーあり: ログを確認してください"
  grep "ERROR" "$RESULT_FILE"
fi
```

---

## Step 6-3: 負荷テスト（接続プール確認）

### `scripts/load-test.sh`

```bash
#!/bin/bash
# RDS Proxy の接続プール動作確認
# 大量同時リクエストで Aurora max_connections を超えないことを確認
set -euo pipefail

ALB_DNS=${1:-$(cd terraform/environments/dev && terraform output -raw alb_dns_name)}
CONCURRENCY=50   # 同時リクエスト数
TOTAL_REQUESTS=200

echo "=== 負荷テスト: ${CONCURRENCY}並列, ${TOTAL_REQUESTS}リクエスト ==="

# ab (Apache Bench) がある場合
if command -v ab &>/dev/null; then
  ab -n $TOTAL_REQUESTS -c $CONCURRENCY "http://$ALB_DNS/items"
else
  # curl で代用
  for i in $(seq 1 $TOTAL_REQUESTS); do
    curl -s -o /dev/null "http://$ALB_DNS/items" &
    if (( i % $CONCURRENCY == 0 )); then
      wait
      echo "Batch $((i / $CONCURRENCY)) 完了"
    fi
  done
  wait
fi

# Aurora の接続数確認（Proxy が max_connections 以内に収めていること）
echo ""
echo "=== Aurora 接続数確認 ==="
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBClusterIdentifier,Value=arpl-aurora-cluster \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || \
    date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 60 \
  --statistics Maximum \
  --output table
```

---

## Step 6-4: 計測結果記録

### `docs/runbook/failover.md`

```markdown
# Aurora フェイルオーバー 検証結果

## 環境
- Aurora Serverless v2: Writer (1a) + Reader (1c)
- RDS Proxy: あり
- アプリ: ECS Fargate (FARGATE_SPOT)

## 測定結果

| 指標 | 計測値 |
|------|--------|
| フェイルオーバー開始〜完了 | XX 秒 |
| アプリへのエラー数 | X件 / Y件中 |
| エラー率 | X.X% |
| フェイルオーバー後のエンドポイント変更 | 不要（Proxy が吸収） |

## RDS Proxy なしの場合（推定）
- Aurora エンドポイントが変わるため、アプリが再接続するまで 30〜60 秒のエラー
- 接続プールがリセットされ一時的な接続スパイクが発生

## 考察
<!-- 自分の言葉で: RDS Proxy が接続断を最小化できた理由 -->
```

---

## Step 6-5: インタビュー準備（STAR 形式）

### 面接想定 Q&A

**Q: Aurora × RDS Proxy の構成で何を解決しましたか？**

```
Situation: ECS Fargate のタスクが起動・停止するたびに DB 接続が断続し、
           Aurora の max_connections が Serverless v2 最小 ACU では低い

Task: 本番相当の接続管理設計を証明するため、接続断なしのローテーション・
      フェイルオーバーを定量的に示す

Action: RDS Proxy で接続プール管理、IAM 認証でパスワード管理を廃止、
        Secrets Manager 7日ローテーションを設定し計測スクリプトで検証

Result: フェイルオーバー中のエラー率 X%、ローテーション中の接続断 0件
```

**Q: Secrets Manager のローテーションで接続断が起きない仕組みを説明してください**

```
4ステップのローテーション中、setSecret フェーズで Aurora の
ALTER USER でパスワードを変更するが、RDS Proxy は
AWSCURRENT と AWSPENDING の両方のパスワードを一時的に受け入れる。
そのため既存の接続（旧パスワード）は切断されず、新しい接続は
新パスワードで確立される。finishSecret で AWSCURRENT が更新された後、
古いパスワードは無効化される。
```

---

## Step 6-6: クリーンアップ

```bash
# 削除保護を一時解除してから destroy
cd terraform/environments/dev

# Aurora 削除保護解除
aws rds modify-db-cluster \
  --db-cluster-identifier arpl-aurora-cluster \
  --no-deletion-protection \
  --apply-immediately

# 少し待つ
sleep 30

# Terraform destroy（順序に注意）
terraform destroy -target=module.ecs_app
terraform destroy -target=module.secrets
terraform destroy -target=module.rds_proxy
terraform destroy -target=module.aurora
terraform destroy -target=module.networking
terraform destroy

# Bootstrap リソース（手動削除）
cd ../bootstrap
# S3 バケットを空にしてから
aws s3 rm s3://arpl-tfstate-XXXXXXXXXXXX --recursive
terraform destroy
```

---

## Step 6-7: README 完成

### `README.md` の骨格

```markdown
# aurora-rds-proxy-lab

## アーキテクチャ

[Mermaidダイアグラム]

## 主要技術スタック

| レイヤー | 技術 |
|--------|------|
| DB | Aurora Serverless v2 (PostgreSQL 15) |
| 接続管理 | RDS Proxy (IAM 認証, TLS必須) |
| 認証情報管理 | Secrets Manager (7日ローテーション) |
| アプリ | ECS Fargate (arm64/FARGATE_SPOT) |
| IaC | Terraform |

## 検証結果

### フェイルオーバー
- エラー率: X% (X件/Y件)
- 復旧時間: XX秒

### ローテーション中の接続断
- エラー数: 0件（RDS Proxy により透過的処理）

## コスト設計（月額見積）

| リソース | 概算 |
|--------|------|
| Aurora Serverless v2 (0.5 ACU idle) | ~$43/月 |
| RDS Proxy | ~$11/月 |
| ECS Fargate (FARGATE_SPOT) | ~$5/月 |
| VPC Endpoint (7本) | ~$50/月 |
| NAT Gateway | $0（廃止） |

## デプロイ

[フェーズ実行手順]
```

---

## フェーズ完了チェック

- [ ] フェイルオーバーテストの計測結果が記録されている
- [ ] ローテーション中のエラー数が 0 件
- [ ] 負荷テスト時の Aurora 接続数が max_connections を超えていない
- [ ] `docs/runbook/failover.md` に自分の言葉で考察を記述
- [ ] STAR 形式の面接回答を 1 つ書いた
- [ ] README.md を完成させた
- [ ] クリーンアップ手順を確認（実行は任意）

## 口頭説明チェック（Phase 6 / 最終）

以下を **15 分** で説明できること:

1. このプロジェクトのアーキテクチャ全体（なぜこの構成にしたか）
2. RDS Proxy が「接続プール」「フェイルオーバー透過化」「ローテーション透過化」を
   それぞれどのメカニズムで実現しているか
3. IAM 認証トークンの仕組みと 15 分有効期限の扱い方
4. 計測した数値を使った具体的な効果の説明
5. 本番環境でこの構成を採用する場合に追加で検討すべき点
   （max_acu の設定、マルチリージョン、監視アラート閾値など）