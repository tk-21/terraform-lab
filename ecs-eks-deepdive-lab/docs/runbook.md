# Runbook: ECS/EKS Deepdive Lab 運用手順

## 共通前提

- Region: ap-northeast-1
- Profile: 適切なAWS認証済み
- kubectl context: deepdive-eks に向いていること

```bash
aws sts get-caller-identity
kubectl config current-context  # → deepdive-eks であること
```

---

## ECS 運用手順

### ヘルスチェック

```bash
# クラスター状態
aws ecs describe-clusters --clusters deepdive-ecs \
  --query 'clusters[0].{status:status,runningTasks:runningTasksCount}'

# サービス状態
aws ecs describe-services --cluster deepdive-ecs \
  --services deepdive-api deepdive-job-worker \
  --query 'services[].{name:serviceName,running:runningCount,desired:desiredCount,status:status}'

# タスク一覧
aws ecs list-tasks --cluster deepdive-ecs --query 'taskArns'
```

### ECS Exec でコンテナに接続

```bash
# タスクARNを取得
TASK_ARN=$(aws ecs list-tasks --cluster deepdive-ecs \
  --service-name deepdive-api \
  --query 'taskArns[0]' --output text)

# コンテナにシェル接続（SSM Session Manager経由）
aws ecs execute-command \
  --cluster deepdive-ecs \
  --task "${TASK_ARN}" \
  --container api \
  --interactive \
  --command "/bin/sh"
```

### スケーリング手動操作

```bash
# Workerを手動スケール（緊急時）
aws ecs update-service \
  --cluster deepdive-ecs \
  --service deepdive-job-worker \
  --desired-count 5
```

### Fargate Spot中断時の確認

```bash
# スポット中断イベントをEventBridgeで確認
aws logs filter-log-events \
  --log-group-name /ecs/deepdive \
  --filter-pattern "SIGTERM" \
  --start-time $(date -d '1 hour ago' +%s000)
```

---

## EKS 運用手順

### ヘルスチェック

```bash
# ノード状態
kubectl get nodes -o wide

# Pod状態
kubectl get pods -n deepdive -o wide

# Karpenter NodePool状態
kubectl get nodeclaim -A

# KEDA ScaledObject状態
kubectl get scaledobject -n deepdive
```

### Pod ログ確認

```bash
# API Pod ログ
kubectl logs -n deepdive -l app=deepdive-api --tail=50

# Worker Pod ログ（複数Pod）
kubectl logs -n deepdive -l app=deepdive-worker --tail=50

# Karpenter ログ（ノードプロビジョニング確認）
kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter --tail=50
```

### Pod に接続

```bash
POD=$(kubectl get pod -n deepdive -l app=deepdive-api -o name | head -1)
kubectl exec -it -n deepdive "${POD}" -- /bin/sh
```

### Karpenter 強制ドレイン

```bash
# 特定ノードを削除（Karpenterが自動再プロビジョニング）
kubectl delete node <node-name>
```

### KEDA スケーリング確認

```bash
# ScaledObjectのトリガー状態
kubectl describe scaledobject deepdive-worker-scaler -n deepdive

# 現在のSQSキュー深度をKEDAが認識しているか
kubectl get hpa -n deepdive
```

---

## SQS 運用手順

```bash
QUEUE_URL=$(aws ssm get-parameter \
  --name /deepdive/sqs-queue-url \
  --query Parameter.Value --output text)

# キュー深度確認
aws sqs get-queue-attributes \
  --queue-url "${QUEUE_URL}" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible

# DLQメッセージ確認
DLQ_URL="${QUEUE_URL}-dlq"
aws sqs receive-message --queue-url "${DLQ_URL}" --max-number-of-messages 10

# DLQ → 本キューへ再送（メッセージ救済）
# ※ DLQのメッセージを手動で本キューへ移動する場合
aws sqs start-message-move-task \
  --source-arn "$(aws sqs get-queue-attributes \
    --queue-url ${DLQ_URL} \
    --attribute-names QueueArn \
    --query Attributes.QueueArn --output text)"
```
