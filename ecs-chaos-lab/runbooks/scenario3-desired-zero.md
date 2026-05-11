# Runbook: シナリオ3 — Desired Count=0 → 手動復旧

## 1. 概要・目的・合格基準

**目的**: FIS `aws:lambda:invoke` で `ecl-desired-count-changer` Lambda を起動し、
ECS Service の DesiredCount を 0 に変更して全 Task を停止する。
その後、同 Lambda を restore モードで実行して DesiredCount=2 に復元し、
意図的なゼロスケール→復旧手順を確立する。

**合格基準**: `restore` 実行後 **180 秒以内** に `RunningCount = 2` に復旧すること

---

## 2. 前提条件

- AWS CLI v2 / `jq` / `curl` インストール済み
- Lambda 関数 `ecl-desired-count-changer` がデプロイ済みであること
- FIS テンプレート ID が確認可能であること（`terraform output scenario3_template_id`）
- ECS Service `ecl-dev-service` が stable 状態（RunningCount = 2）

### Lambda デプロイ確認

```bash
# Lambda 関数が存在することを確認
aws lambda get-function \
  --function-name ecl-desired-count-changer \
  --region ap-northeast-1 \
  --query 'Configuration.{State:State,LastModifiedTime:LastModifiedTime}'
```

---

## 3. 実験手順

### Step 1: 環境変数の設定

```bash
export SCENARIO3_TEMPLATE_ID=$(cd terraform/environments/dev && terraform output -raw scenario3_template_id)
export CLUSTER_NAME=$(cd terraform/environments/dev && terraform output -raw cluster_name)
export SERVICE_NAME=$(cd terraform/environments/dev && terraform output -raw service_name)
export LAMBDA_FUNCTION_NAME=$(cd terraform/environments/dev && terraform output -raw lambda_function_name)
export ALB_DNS=$(cd terraform/environments/dev && terraform output -raw alb_dns_name)
```

### Step 2: DesiredCount=0 に変更（全 Task 停止）

```bash
./scripts/run_desired_zero.sh set_zero
```

### Step 3: RunningCount=0 を確認

```bash
# 別ターミナルで Service を監視
./scripts/watch_service.sh

# または直接確認
aws ecs describe-services \
  --cluster ecl-dev-cluster --services ecl-dev-service \
  --region ap-northeast-1 \
  --query 'services[0].{desired:desiredCount,running:runningCount}'
```

### Step 4: ALB が 503 を返すことを確認

```bash
curl -I "http://$ALB_DNS/health"
# 期待値: HTTP/1.1 503 Service Unavailable
```

### Step 5: Service を復旧（DesiredCount=2 に復元）

```bash
./scripts/run_desired_zero.sh restore
```

### Step 6: Service stable 確認

`run_desired_zero.sh restore` が内部で `aws ecs wait services-stable` を実行するため、
stable になるまで待機した後に結果を出力する。

---

## 4. Terraform lifecycle 注意事項

ECS モジュールに `lifecycle { ignore_changes = [desired_count] }` が設定されていない場合、
次回の `terraform apply` で `desired_count` が Terraform 管理値（デフォルト 2）に上書きされる。

確認方法:

```bash
grep -A 3 "lifecycle" terraform/modules/ecs/main.tf
```

`ignore_changes = [desired_count]` が含まれていない場合は、Lambda による変更が
terraform apply で巻き戻されることを把握した上で運用すること。

---

## 5. トラブルシューティング

### Lambda invoke が失敗する場合

```bash
# Lambda の実行ロールが ECS UpdateService 権限を持つか確認
aws lambda get-function \
  --function-name ecl-desired-count-changer \
  --region ap-northeast-1 \
  --query 'Configuration.Role'

# Lambda ログを確認
aws logs tail /aws/lambda/ecl-desired-count-changer --follow --region ap-northeast-1
```

### Service が stable にならない場合

```bash
# Task が起動失敗している場合はイベントを確認
aws ecs describe-services \
  --cluster ecl-dev-cluster --services ecl-dev-service \
  --region ap-northeast-1 \
  --query 'services[0].events[:10]'

# ECR イメージが存在するか確認
aws ecr describe-images \
  --repository-name ecl-dev-nginx \
  --region ap-northeast-1
```

### restore 後も DesiredCount が 0 のまま

```bash
# Lambda が正しく UpdateService を呼び出したか Lambda ログを確認
aws logs tail /aws/lambda/ecl-desired-count-changer --region ap-northeast-1

# 手動でフォールバック
aws ecs update-service \
  --cluster ecl-dev-cluster \
  --service ecl-dev-service \
  --desired-count 2 \
  --region ap-northeast-1
```
