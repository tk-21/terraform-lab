# Runbook: シナリオ2 — ネットワーク遮断

## 1. 概要・目的・合格基準

**目的**: FIS `aws:ecs:task-network-blackhole-port` で TCP:80 インバウンドを遮断し、
ALB が Unhealthy Target を切り離して 503 を返した後、FIS 終了後に自動復旧することを確認する。

**合格基準**:
1. FIS 実験中に ALB `/health` が HTTP 503 を返すこと
2. FIS 実験終了後 **60 秒以内** に HTTP 200 に復旧すること

---

## 2. 前提条件

- AWS CLI v2 / `jq` / `curl` インストール済み
- ECS Service が awsvpc ネットワークモードで稼働していること
- ALB Target Group `target_type = ip` で設定されていること
- ECS Service `ecl-dev-service` が stable 状態（RunningCount = 2）

---

## 3. 実験前チェックリスト

```bash
# ALB の HealthyHostCount を確認（2 であること）
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HealthyHostCount \
  --dimensions Name=TargetGroup,Value=$(cd terraform/environments/dev && terraform output -raw target_group_arn | cut -d: -f6) \
  --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 60 --statistics Average \
  --region ap-northeast-1

# ALB が正常に 200 を返すことを確認
curl -I "http://$ALB_DNS/health"

# Task が awsvpc で ENI を持つことを確認
aws ecs list-tasks --cluster ecl-dev-cluster --service-name ecl-dev-service --region ap-northeast-1
```

---

## 4. 実験手順

### Step 1: 環境変数の設定

```bash
export SCENARIO2_TEMPLATE_ID=$(cd terraform/environments/dev && terraform output -raw scenario2_template_id)
export CLUSTER_NAME=$(cd terraform/environments/dev && terraform output -raw cluster_name)
export SERVICE_NAME=$(cd terraform/environments/dev && terraform output -raw service_name)
export ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
```

### Step 2: 別ターミナルで Service 監視を起動

```bash
# 別ターミナル1: ECS Service 監視
./scripts/watch_service.sh
```

### Step 3: 別ターミナルで ALB レスポンスを継続監視

```bash
# 別ターミナル2: ALB レスポンスコードを 5 秒ごとに確認
watch -n 5 "curl -s -o /dev/null -w '%{http_code}' http://$ALB_DNS/health"
```

### Step 4: 実験スクリプトを実行

```bash
# dry-run で確認
./scripts/run_network_disruption.sh --dry-run

# 実験実行
./scripts/run_network_disruption.sh
```

---

## 5. 観測ポイント

### FIS 実験中の期待動作

1. FIS が Task の ENI に一時的なネットワーク ACL ルールを追加
2. ALB ヘルスチェックが失敗し始める（タイムアウト後）
3. ALB Target が Unhealthy 判定され、トラフィックが切り離される
4. ALB が HTTP 503 を返す（Unhealthy Target のみの場合）

### ALB アクセスログの確認方法

```bash
# ALB アクセスログが S3 に設定されている場合
# Target Status Code = 5XX / Target Status = - の行を確認

# または CloudWatch Logs Insights で確認
aws logs start-query \
  --log-group-name /aws/alb/ecl-dev-alb \
  --start-time $(date -d '30 minutes ago' +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, target_status_code | filter target_status_code >= 500 | sort @timestamp desc' \
  --region ap-northeast-1
```

---

## 6. ロールバック

FIS 実験を手動停止する（実験が完了しない場合やサービスが予期せず全断した場合）。

```bash
# 実験 ID を確認
aws fis list-experiments --region ap-northeast-1 \
  --query 'experiments[?state.status==`running`].[id,state.status]'

# 実験を停止
aws fis stop-experiment --id $EXPERIMENT_ID --region ap-northeast-1
```

---

## 7. トラブルシューティング

### HTTP 503 が観測されない（遮断されない）場合

- Task が awsvpc モードで起動していることを確認（`networkMode` が `awsvpc` であること）
- FIS 実験の `percentage` が正しく設定されているか確認（PERCENT(100) で全 Task を対象にする）
- FIS 実験ログを確認: CloudWatch Logs `/aws/fis/ecl-dev`

### HealthyHostCount が変化しない場合

- ALB ヘルスチェック間隔と unhealthy threshold の設定を確認
- デフォルトでは threshold=3 の場合、3 回連続失敗で Unhealthy 判定される（最大 90 秒）
- FIS 実験の duration が短すぎる可能性がある（`PT3M` 以上を推奨）

### FIS 実験終了後も復旧しない場合

```bash
# Task を手動で再起動
aws ecs update-service \
  --cluster ecl-dev-cluster \
  --service ecl-dev-service \
  --force-new-deployment \
  --region ap-northeast-1
```
