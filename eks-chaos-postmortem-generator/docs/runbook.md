# 運用ランブック

## 事前準備

### 1. Chatwork APIキーの設定

terraform apply後、Secrets Managerに手動でAPIキーを設定する。

```bash
aws secretsmanager put-secret-value \
  --secret-id "eks-chaos-postmortem/chatwork-api-key-dev" \
  --secret-string '{"api_key": "YOUR_CHATWORK_API_KEY", "room_id": "YOUR_ROOM_ID"}' \
  --region ap-northeast-1
```

ChatworkのAPIキーはChatwork設定画面 > API Token から取得する。
Room IDはChatworkのURLから確認できる（`https://www.chatwork.com/#!rid{ROOM_ID}`）。

### 2. EKSクラスターへの接続確認

```bash
# kubeconfigの更新
aws eks update-kubeconfig \
  --name eks-chaos-postmortem-dev \
  --region ap-northeast-1

# 接続確認
kubectl get nodes
kubectl get pods -n chaos-target
```

### 3. サンプルアプリのデプロイ

```bash
kubectl apply -f k8s/sample-app/namespace.yaml
kubectl apply -f k8s/sample-app/deployment.yaml

# デプロイ確認（3 Podが Running になるまで待機）
kubectl get pods -n chaos-target -w
```

---

## FIS実験の実行手順

### 実験テンプレートIDの確認

```bash
# Terraformのoutputから確認
cd terraform/environments/dev
terraform output
```

### Pod Kill実験

```bash
# 実験開始
aws fis start-experiment \
  --experiment-template-id <pod_kill_template_id> \
  --region ap-northeast-1

# Podの状態をリアルタイム監視
kubectl get pods -n chaos-target -w
```

期待動作: 3つのPodが削除され、Kubernetesの自己修復により2分以内に再起動する。

### Node Termination実験

```bash
aws fis start-experiment \
  --experiment-template-id <node_termination_template_id> \
  --region ap-northeast-1
```

> ⚠️ chaosノードグループのノードが終了する。Karpenterが自動で新規ノードをプロビジョニングする。

### Network Latency実験

```bash
aws fis start-experiment \
  --experiment-template-id <network_latency_template_id> \
  --region ap-northeast-1
```

期待動作: chaos-targetネームスペースのPodに100msのネットワーク遅延が60秒間注入される。

### CPU Stress実験

```bash
aws fis start-experiment \
  --experiment-template-id <cpu_stress_template_id> \
  --region ap-northeast-1
```

期待動作: chaos-targetネームスペースのPodにCPUストレスが60秒間注入される（80%負荷）。

---

## ポストモーテムの確認

### Chatwork通知の確認

実験完了から3〜5分後にChatworkの指定ルームに通知が届く。
通知が届かない場合はトラブルシューティングを参照。

### S3レポートの確認

```bash
# バケット内のレポート一覧
aws s3 ls s3://eks-chaos-postmortem-reports-<account_id>-dev/reports/ --recursive

# presigned URLの手動生成（既存レポートのURL再発行）
aws s3 presign \
  s3://eks-chaos-postmortem-reports-<account_id>-dev/reports/<type>/<experiment_id>/postmortem.html \
  --expires-in 604800
```

### Step Functions実行履歴の確認

```bash
# 最新の実行履歴を確認
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:ap-northeast-1:<account_id>:stateMachine:eks-chaos-postmortem-postmortem-workflow-dev \
  --max-results 5

# 特定実行の詳細
aws stepfunctions describe-execution \
  --execution-arn <execution_arn>
```

---

## トラブルシューティング

### ポストモーテムが生成されない場合

1. EventBridgeルールの確認
   ```bash
   aws events list-rules --name-prefix "eks-chaos-postmortem" --region ap-northeast-1
   ```

2. fis-event-handler Lambdaのログ確認
   ```bash
   aws logs tail /aws/lambda/eks-chaos-postmortem-fis-event-handler-dev --follow
   ```

3. DynamoDBで重複フラグが立っていないか確認
   ```bash
   aws dynamodb scan --table-name eks-chaos-postmortem-experiments-dev
   ```

4. Step Functionsの実行履歴を確認（上記コマンド参照）

### Bedrockバリデーションエラーの場合

bedrock-analyzerが6項目バリデーションに失敗している場合:

```bash
aws logs tail /aws/lambda/eks-chaos-postmortem-bedrock-analyzer-dev --follow
```

主な原因:
- 収集データが少なすぎてBedrockが十分な情報を持てない
- Bedrockのレスポンスが8,000トークンを超えた（data-collectorでのデータ圧縮を確認）
- ap-northeast-1でClaude Sonnet 3.5が一時的に利用不可

### Chatwork通知が来ない場合

1. Secrets Managerのシークレット設定を確認
   ```bash
   aws secretsmanager get-secret-value \
     --secret-id "eks-chaos-postmortem/chatwork-api-key-dev" \
     --region ap-northeast-1
   ```

2. notifier Lambdaのログ確認
   ```bash
   aws logs tail /aws/lambda/eks-chaos-postmortem-notifier-dev --follow
   ```

3. Chatwork APIキーの有効期限を確認（Chatwork設定画面で確認）

4. room_idが正しいか確認（数値のみ、`#!rid` 以降の部分）

---

## コスト管理

### 検証完了後のクラスター停止手順

EKSクラスターは高コスト（~$72/月）のため、検証後はノードグループをスケールダウンする。

```bash
# ノードグループを0台にスケールダウン
aws eks update-nodegroup-config \
  --cluster-name eks-chaos-postmortem-dev \
  --nodegroup-name baseline \
  --scaling-config minSize=0,maxSize=2,desiredSize=0

aws eks update-nodegroup-config \
  --cluster-name eks-chaos-postmortem-dev \
  --nodegroup-name chaos \
  --scaling-config minSize=0,maxSize=2,desiredSize=0
```

> クラスター自体を削除する場合は `terraform destroy` を実行する（次セクション参照）。

### 月次コスト確認方法

```bash
# AWS Cost Explorerで確認（プロジェクトタグでフィルタ）
aws ce get-cost-and-usage \
  --time-period Start=2026-04-01,End=2026-04-30 \
  --granularity MONTHLY \
  --filter '{"Tags":{"Key":"Project","Values":["eks-chaos-postmortem-generator"]}}' \
  --metrics BlendedCost
```

---

## クリーンアップ

### terraform destroyの手順

```bash
cd terraform/environments/dev

# S3バケットのオブジェクトを先に削除（バケット削除前に必要）
BUCKET="eks-chaos-postmortem-reports-$(aws sts get-caller-identity --query Account --output text)-dev"
aws s3 rm s3://$BUCKET --recursive

# terraform destroy実行
terraform destroy -var-file="terraform.tfvars"
```

### 注意事項（S3バケットの手動削除）

S3バケットはTerraformの `force_destroy = false` 設定のため、オブジェクトが残っている場合はdestroyが失敗する。
上記の `aws s3 rm` コマンドでオブジェクトを先に削除してから terraform destroy を実行すること。

Secrets Managerのシークレットは7日間の削除保護があるため、即時削除には `--force-delete-without-recovery` オプションが必要:

```bash
aws secretsmanager delete-secret \
  --secret-id "eks-chaos-postmortem/chatwork-api-key-dev" \
  --force-delete-without-recovery
```
