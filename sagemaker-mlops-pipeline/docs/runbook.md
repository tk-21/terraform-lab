# Runbook: SageMaker MLOps Pipeline

## 1. 初期デプロイ

```bash
# 1. Chatworkパラメータを設定（初回のみ）
aws ssm put-parameter --name /smp/chatwork/room_id \
  --value YOUR_ROOM_ID --type SecureString --region ap-northeast-1
aws ssm put-parameter --name /smp/chatwork/api_token \
  --value YOUR_API_TOKEN --type SecureString --region ap-northeast-1

# 2. Terraformデプロイ
bash scripts/deploy.sh

# 3. パイプライン実行・E2Eテスト
bash scripts/run_pipeline.sh
```

---

## 2. モデルデプロイ手順

### 2-1. パイプライン完了後の確認

```bash
# Model Registryの最新パッケージARNを取得
aws sagemaker list-model-packages \
  --model-package-group-name smp-model-group \
  --sort-by CreationTime --sort-order Descending \
  --query 'ModelPackageSummaryList[0].ModelPackageArn' \
  --output text --region ap-northeast-1
```

### 2-2. モデル承認（Chatwork通知確認後）

```bash
aws sagemaker update-model-package \
  --model-package-arn <MODEL_PACKAGE_ARN> \
  --model-approval-status Approved \
  --region ap-northeast-1
```

承認後、EventBridge が CodePipeline を自動起動してデプロイが開始される。

### 2-3. デプロイ完了確認

```bash
aws sagemaker describe-endpoint \
  --endpoint-name smp-inference-endpoint \
  --query 'EndpointStatus' \
  --output text --region ap-northeast-1
# → "InService" になれば完了
```

---

## 3. 推論テスト

```bash
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name smp-inference-endpoint \
  --content-type text/csv \
  --body "1.0,0.5,-0.3,1.2,0.8,0.1,-0.5,1.1,0.3,-0.2" \
  --region ap-northeast-1 \
  /tmp/response.json
cat /tmp/response.json
```

---

## 4. Model Monitor 運用

### 4-1. ベースライン生成（初回のみ）

```bash
ROLE_ARN=$(cd terraform && terraform output -raw pipeline_role_arn)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

python monitor/data_quality_baseline.py \
  --role-arn "$ROLE_ARN" \
  --artifacts-bucket "smp-artifacts-${ACCOUNT_ID}" \
  --data-bucket "smp-data-${ACCOUNT_ID}"

python monitor/model_quality_baseline.py \
  --role-arn "$ROLE_ARN" \
  --artifacts-bucket "smp-artifacts-${ACCOUNT_ID}" \
  --endpoint-name smp-inference-endpoint
```

### 4-2. 監視スケジュールの状態確認

```bash
aws sagemaker list-monitoring-schedules \
  --query 'MonitoringScheduleSummaries[].{Name:MonitoringScheduleName,Status:MonitoringScheduleStatus}' \
  --output table --region ap-northeast-1
```

### 4-3. ドリフト検知アラームの確認

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix smp- \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' \
  --output table --region ap-northeast-1
```

---

## 5. 障害対応

### 5-1. パイプライン実行が失敗した場合

```bash
# 失敗ステップを確認
aws sagemaker list-pipeline-execution-steps \
  --pipeline-execution-arn <EXECUTION_ARN> \
  --query 'PipelineExecutionSteps[?StepStatus==`Failed`]' \
  --output json --region ap-northeast-1
```

よくある原因：
- **EvaluationStep失敗**: テストデータが存在しない → `run_pipeline.sh` を再実行
- **TrainingStep失敗（スポット中断）**: スポットキャパシティ不足 → 数分後に再実行
- **ConditionStep→FailStep**: 精度が閾値未満 → ハイパーパラメータを調整して再実行

### 5-2. Lambda通知が届かない場合

```bash
# approval_notifier のCloudWatch Logsを確認
aws logs tail /aws/lambda/smp-approval-notifier --follow --region ap-northeast-1

# SSMパラメータの存在確認
aws ssm get-parameters \
  --names /smp/chatwork/room_id /smp/chatwork/api_token \
  --with-decryption --region ap-northeast-1 \
  --query 'Parameters[].Name'
```

### 5-3. Endpointが InService にならない場合

```bash
# Endpoint更新イベントを確認
aws sagemaker describe-endpoint \
  --endpoint-name smp-inference-endpoint \
  --region ap-northeast-1 \
  --query '{Status:EndpointStatus,FailureReason:FailureReason}'
```

---

## 6. クリーンアップ

```bash
# Endpointを削除（コスト節約）
aws sagemaker delete-endpoint \
  --endpoint-name smp-inference-endpoint \
  --region ap-northeast-1

# 全リソースを削除する場合
cd terraform && terraform destroy -var="environment=dev" -auto-approve
```

> **注意**: `terraform destroy` は S3 バケットのデータも削除する。
> 学習済みモデルを保持したい場合は事前にバックアップすること。
