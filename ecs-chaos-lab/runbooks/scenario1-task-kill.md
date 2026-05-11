# Runbook: シナリオ1 — ECS Task 強制停止

## 1. 概要・目的・合格基準

**目的**: ECS FIS `aws:ecs:task-kill` アクションで全 Task を強制停止し、
ECS Service Controller が自動的に Task を再起動することを確認する。

**合格基準**: FIS 実験完了後 **120 秒以内** に `RunningCount = 2` に復旧すること

---

## 2. 前提条件

- AWS CLI v2 インストール済み
- `jq` インストール済み
- 実行権限: `ecs:DescribeServices`, `fis:StartExperiment`, `fis:GetExperiment`
- ECS Service `ecl-dev-service` が stable 状態（RunningCount = 2）

---

## 3. 実験前チェックリスト

```bash
# RunningCount が 2 であることを確認
aws ecs describe-services \
  --cluster ecl-dev-cluster --services ecl-dev-service \
  --region ap-northeast-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'

# CloudWatch アラーム状態が OK であることを確認
aws cloudwatch describe-alarms \
  --alarm-names ecl-dev-fis-stop-running-task-low \
  --region ap-northeast-1 \
  --query 'MetricAlarms[0].StateValue'

# ALB が Healthy であることを確認
curl -I http://$ALB_DNS/health
```

---

## 4. 実験手順

### Step 1: 環境変数の設定

```bash
export SCENARIO1_TEMPLATE_ID=$(cd terraform/environments/dev && terraform output -raw scenario1_template_id)
export CLUSTER_NAME=$(cd terraform/environments/dev && terraform output -raw cluster_name)
export SERVICE_NAME=$(cd terraform/environments/dev && terraform output -raw service_name)
export ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
```

### Step 2: 別ターミナルで Service 監視を起動

```bash
# 別ターミナルで実行
./scripts/watch_service.sh
```

### Step 3: 実験スクリプトを実行

```bash
# dry-run で確認
./scripts/run_task_kill.sh --dry-run

# 実験実行
./scripts/run_task_kill.sh
```

### Step 4: 結果確認

スクリプトが自動的に結果サマリーを出力する。
FIS ログは CloudWatch Logs `/aws/fis/ecl-dev` で確認可能。

---

## 5. 合否判定基準と記録フォーマット

```
実験日時: YYYY-MM-DD HH:MM
実験 ID: EXP-XXXXXXXXXXXX
実験前 RunningCount: 2
実験後 RunningCount: [値]
復旧時間: [秒]
判定: ✅ 合格（120秒以内に RunningCount=2 に復旧） / ❌ 不合格
```

---

## 6. ロールバック

実験後に RunningCount が回復しない場合は手動で desired_count を設定する。

```bash
aws ecs update-service \
  --cluster ecl-dev-cluster \
  --service ecl-dev-service \
  --desired-count 2 \
  --region ap-northeast-1

# Service stable を待機
aws ecs wait services-stable \
  --cluster ecl-dev-cluster \
  --services ecl-dev-service \
  --region ap-northeast-1
```

---

## 7. トラブルシューティング

### Task が再起動しない場合

```bash
# ECS Events を確認
aws ecs describe-services \
  --cluster ecl-dev-cluster --services ecl-dev-service \
  --region ap-northeast-1 \
  --query 'services[0].events[:10]'

# Task が起動失敗している場合はログを確認
aws logs tail /ecs/ecl-dev --follow --region ap-northeast-1
```

### FIS 実験が即座に失敗する場合

```bash
# FIS 実行ロールの権限を確認
aws iam simulate-principal-policy \
  --policy-source-arn $(cd terraform/environments/dev && terraform output -raw fis_role_arn) \
  --action-names ecs:StopTask ecs:ListTasks ecs:DescribeTasks \
  --resource-arns "*"
```

### CloudWatch アラームが ALARM 状態の場合

実験前にアラームが ALARM 状態の場合、FIS 実験が即座に停止条件を満たして終了する。
まず RunningCount を確認し、サービスが正常であることを確認してから再実行すること。
