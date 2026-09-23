# eks-chaos-postmortem-generator

> Chaos Engineering × AI — 障害を意図的に起こし、AIが人間より先にポストモーテムを書く

AWS Fault Injection Service（FIS）で EKS クラスターに意図的な障害を注入し、Amazon Bedrock が自動でポストモーテムを生成して Amazon SNS に通知する SRE プラットフォームです。

この README は、初回セットアップから FIS 実験、結果確認、後片付けまでを順番に実行できるハンズオン手順として書いています。

詳細な内部構成を知りたい場合は [ARCHITECTURE.md](ARCHITECTURE.md) を参照してください。

---

## このハンズオンで得られること

このハンズオンを通して、次の実践的な理解を得られます。

- EKS 上で Chaos Engineering を安全に実施する基本パターン
- FIS、EventBridge、Step Functions、Lambda を連携させるイベント駆動アーキテクチャ
- CloudWatch、CloudTrail、Kubernetes Events を使った障害データの集め方
- Amazon Bedrock を使って障害情報からポストモーテムを自動生成する流れ
- SRE 観点での冪等性、最小権限 IAM、StopCondition、可観測性の設計ポイント

---

## アーキテクチャ概要

```text
FIS実験トリガー
    ↓
AWS Fault Injection Service（Pod Kill / Node Termination / Network Latency / CPU Stress）
    ↓ EventBridge
fis-event-handler Lambda（DynamoDB冪等性チェック）
    ↓ Step Functions
① data-collector  → CloudWatch Logs / Container Insights / CloudTrail / K8s Events
② bedrock-analyzer → Claude Sonnet 4.6 でポストモーテム生成（6項目バリデーション）
③ report-formatter → HTMLレポート生成 → S3保存 → presigned URL
④ notifier         → Amazon SNS通知
```

補足資料:

- 全体設計: [ARCHITECTURE.md](ARCHITECTURE.md)
- 実行手順: この README のハンズオンセクション

---

## 使用技術スタック

| カテゴリ | 技術 |
|---|---|
| IaC | Terraform |
| コンテナ基盤 | Amazon EKS 1.30 |
| カオスエンジニアリング | AWS Fault Injection Service |
| サーバーレス | AWS Lambda（Python 3.12 / arm64） |
| ワークフロー | AWS Step Functions |
| AI | Amazon Bedrock（Claude Sonnet 4.6） |
| イベント駆動 | Amazon EventBridge |
| ストレージ | Amazon S3, Amazon DynamoDB |
| 通知 | Amazon SNS API |
| 可観測性 | CloudWatch, X-Ray, Lambda Powertools |
| CI/CD | GitHub Actions + OIDC |

---

## このハンズオンでできること

この README の手順を完了すると、次の流れを実際に確認できます。

1. Terraform で EKS / FIS / Lambda / Step Functions / S3 / EventBridge を構築する
2. `chaos-target` namespace にサンプルアプリを配置する
3. FIS 実験を 1 つ実行する
4. EventBridge から Step Functions が起動し、AI ポストモーテムが生成されることを確認する
5. Amazon SNS と S3 にレポートが出力されることを確認する

---

## 前提条件

以下を事前に用意してください。

- AWS アカウント
- `ap-northeast-1` で EKS / FIS / Bedrock / Step Functions / Lambda / SNS / CloudWatch が利用可能であること
- AWS CLI インストール済み
- Terraform `>= 1.6`
- `kubectl`
- Git
- SNS通知を受信するメールアドレス
- Bedrock で `Claude Sonnet 4.6` を利用できること
- **Chaos Mesh がインストール済み** であること（Network Latency / CPU Stress 実験に必須）

推奨確認コマンド:

```bash
aws --version
terraform version
kubectl version --client
```

---

## 事前確認

### 1. リポジトリを取得する

```bash
git clone <repository_url>
cd eks-chaos-postmortem-generator
```

### 2. AWS 認証状態を確認する

```bash
aws sts get-caller-identity
aws configure get region
```

確認ポイント:

- 想定どおりの AWS アカウント ID が表示される
- 利用リージョンが `ap-northeast-1` であるか、もしくはコマンド実行時に `--region ap-northeast-1` を付ける運用にする

### 3. Bedrock 利用可否を確認する

Claude Sonnet 4.6 へのアクセスがないと、ポストモーテム生成は最後まで成功しません。

```bash
aws bedrock list-foundation-models \
  --region ap-northeast-1 \
  --by-provider anthropic \
  --query "modelSummaries[?contains(modelName, \`Sonnet\`)].{ModelId:modelId,Name:modelName,Status:modelLifecycle.status}" \
  --output table
```

2026年9月時点の `ap-northeast-1` における Claude Sonnet 系モデルの確認結果:

```text
| ModelId                                     | Name               | Status |
|---------------------------------------------|--------------------|--------|
| anthropic.claude-sonnet-4-20250514-v1:0     | Claude Sonnet 4    | LEGACY |
| anthropic.claude-sonnet-4-6                  | Claude Sonnet 4.6  | ACTIVE |
| anthropic.claude-sonnet-4-5-20250929-v1:0   | Claude Sonnet 4.5  | ACTIVE |
| anthropic.claude-sonnet-5                    | Claude Sonnet 5    | ACTIVE |
```

`Claude 3.5 Sonnet` は一覧に表示されないため、このプロジェクトでは `ACTIVE` の `Claude Sonnet 4.6` を使用します。Terraform、Lambda、IAM ポリシーで参照するモデル ID は `anthropic.claude-sonnet-4-6` に統一しています。

### 4. SNS通知先を準備する

通知を受信するメールアドレスを用意してください。SNSトピックと購読登録は後述の手順で設定します。

---

## ハンズオン全体像

この README では次の順番で進めます。

1. Terraform バックエンド用 S3 バケットを作る
2. `terraform.tfvars` を設定する
3. Terraform でインフラを構築する
4. EKS に接続する
5. Chaos Mesh をインストールする（Network Latency / CPU Stress 実験の前提）
6. Kubernetes の初期セットアップを行う（FIS 用 ServiceAccount / RBAC）
7. サンプルアプリをデプロイする
8. SNSのメール購読を登録する
9. FIS 実験テンプレート ID を確認する
10. 最初の FIS 実験を実行する
11. Step Functions / S3 / Amazon SNS で結果を確認する
12. 追加の実験を試す
13. 必要に応じてコスト削減またはクリーンアップする

---

## Step 1. Terraform バックエンドを準備する

このプロジェクトは Terraform state を S3 バックエンドに保存します。まず state 用バケットを作成します。

```bash
aws s3 mb s3://eks-chaos-postmortem-tfstate --region ap-northeast-1
```

バケットの存在確認:

```bash
aws s3api head-bucket \
  --bucket eks-chaos-postmortem-tfstate \
  --region ap-northeast-1
echo $?
```

`head-bucket` は成功時に何も表示しません。続けて実行した `echo $?` が `0` なら、バケットが存在し、現在の認証情報でアクセスできています。

バケット内のオブジェクトを確認する場合:

```bash
aws s3 ls s3://eks-chaos-postmortem-tfstate --region ap-northeast-1
```

作成直後のバケットは空なので、このコマンドが何も表示しなくても正常です。

注意:

- バケット名 `eks-chaos-postmortem-tfstate` が既に他環境で使われている場合は、Terraform 側の backend 定義も合わせて変更が必要です
- このリポジトリの現在のコードは、この固定名を前提にしています

---

## Step 2. `terraform.tfvars` を設定する

このリポジトリには既に `terraform/environments/dev/terraform.tfvars` があります。まず中身を確認します。

```bash
cat terraform/environments/dev/terraform.tfvars
```

初期状態:

```hcl
aws_account_id = "123456789012"
```

これを自分の AWS アカウント ID に変更してください。

確認コマンド:

```bash
aws sts get-caller-identity --query Account --output text
```

編集後の例:

```hcl
aws_account_id = "111122223333"
```

---

## Step 3. Terraform でインフラを構築する

作業ディレクトリを `dev` 環境へ移動します。

```bash
cd terraform/environments/dev
```

### 3-1. 初期化

```bash
terraform init
```

期待すること:

- backend の初期化が成功する
- AWS / TLS プロバイダーが取得される

### 3-2. フォーマット確認

```bash
terraform fmt -check -recursive ../..
```

### 3-3. 構文と依存の検証

```bash
terraform validate
```

### 3-4. 実行計画の確認

```bash
terraform plan -var-file="terraform.tfvars"
```

この時点で確認したい主なリソース:

- VPC
- EKS クラスター
- `baseline` / `chaos` ノードグループ
- FIS 実験テンプレート 4 種
- S3 レポートバケット
- Lambda 5 本
- Step Functions ステートマシン
- EventBridge ルール
- DynamoDB テーブル
- SNS通知トピック

### 3-5. 適用

```bash
terraform apply -var-file="terraform.tfvars"
```

作成には数分かかります。EKS 作成が一番時間を使います。

### 3-6. 出力確認

```bash
terraform output
```

このあと使うので、少なくとも以下を確認してください。

- EKS クラスター名
- FIS 実験テンプレート ID
- SNS 通知トピック ARN

作業が終わったら、プロジェクトルートへ戻ります。

```bash
cd ../../..
```

---

## Step 4. SNSのメール購読を登録する

Terraform適用後、出力されたSNSトピックARNを確認します。

```bash
SNS_TOPIC_ARN=$(terraform -chdir=terraform/environments/dev output -raw sns_topic_arn)
```

通知を受信するメールアドレスを購読登録します。

```bash
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "YOUR_EMAIL_ADDRESS" \
  --region ap-northeast-1
```

登録したメールアドレスに届く確認メールで **Confirm subscription** を選択してください。確認が完了するまでSNS通知は配信されません。

購読状態の確認:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$SNS_TOPIC_ARN" \
  --region ap-northeast-1
```

---

## Step 5. EKS に接続する

まず kubeconfig を更新します。

```bash
aws eks update-kubeconfig \
  --name eks-chaos-postmortem-dev \
  --region ap-northeast-1
```

接続確認:

```bash
kubectl get nodes
kubectl get ns
```

期待すること:

- ノードが表示される
- EKS API に接続できる

---

## Step 5-2. Chaos Mesh のインストール

Network Latency / CPU Stress 実験を実行するために、EKS クラスターに Chaos Mesh をインストールする必要があります。

### 5-2-1. Helm リポジトリの追加

```bash
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
```

### 5-2-2. Chaos Mesh のインストール

```bash
helm install chaos-mesh chaos-mesh/chaos-mesh \
  -n chaos-mesh-system \
  --create-namespace
```

### 5-2-3. インストール確認

```bash
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/instance=chaos-mesh \
  -n chaos-mesh-system \
  --timeout=300s

kubectl get pods -n chaos-mesh-system
kubectl get crd | grep chaos-mesh
```

期待すること:

- `chaos-mesh-controller-manager` Pod が `Running`
- 複数の Chaos Mesh CRD（`networkchaos`, `stresschaos`, `podchaos` など）が登録されている

---

## Step 5-3. Kubernetes の初期セットアップ（FIS 用 ServiceAccount と RBAC）

FIS が実験を実行するために必要な ServiceAccount と RBAC 権限を設定します。

### 5-3-1. `chaos-target` namespace の作成

```bash
kubectl create namespace chaos-target
```

### 5-3-2. FIS 実行用 ServiceAccount の作成

```bash
kubectl create serviceaccount fis-sa -n chaos-target
```

### 5-3-3. Pod Delete 権限を付与（Pod Kill 実験用）

```bash
kubectl create clusterrole fis-pod-delete --verb=delete --resource=pods
kubectl create clusterrolebinding fis-pod-delete --clusterrole=fis-pod-delete --serviceaccount=chaos-target:fis-sa
```

### 5-3-4. Chaos Mesh リソース操作権限を付与（Network Latency / CPU Stress 実験用）

Chaos Mesh CRD に対する権限を設定します：

```bash
kubectl create clusterrole fis-chaos-mesh \
  --verb=create,delete,get,list,patch,watch \
  --resource=networkchaos.chaos-mesh.org,stresschaos.chaos-mesh.org

kubectl create clusterrolebinding fis-chaos-mesh \
  --clusterrole=fis-chaos-mesh \
  --serviceaccount=chaos-target:fis-sa
```

権限確認:

```bash
kubectl auth can-i create networkchaos --as=system:serviceaccount:chaos-target:fis-sa -n chaos-target
kubectl auth can-i delete pods --as=system:serviceaccount:chaos-target:fis-sa -n chaos-target
```

期待すること:

- 両コマンドが `yes` を返す

---

## Step 6. サンプルアプリをデプロイする

Chaos 実験対象の namespace と Deployment を適用します。

```bash
kubectl apply -f k8s/sample-app/namespace.yaml
kubectl apply -f k8s/sample-app/deployment.yaml
```

**重要**: `k8s/sample-app/deployment.yaml` に、Pod Kill 実験で使用するラベル `chaos-target: pod-kill` を追加します。

例（deployment.yaml の spec.template.metadata.labels に追加）:

```yaml
apiVersion: v1
kind: Pod
metadata:
  labels:
    app: sample-app
    chaos-target: pod-kill    # FIS Pod Kill 実験でこのラベルをセレクタとして使用
```

状態確認:

```bash
kubectl get pods -n chaos-target
kubectl get pods -n chaos-target -w
kubectl get pods -n chaos-target --show-labels
```

期待すること:

- `sample-app` の Pod が 3 つ起動する
- `Running` になる
- `chaos-target=pod-kill` ラベルが付与されている

追加確認:

```bash
kubectl describe deployment sample-app -n chaos-target
kubectl get nodes --show-labels | grep chaos-target
```

---

## Step 7. SNSのメール購読を登録する

Terraform適用後、出力されたSNSトピックARNを確認します。

```bash
SNS_TOPIC_ARN=$(cd terraform/environments/dev && terraform output -raw sns_topic_arn && cd ../../..)
```

通知を受信するメールアドレスを購読登録します。

```bash
aws sns subscribe \
  --topic-arn "$SNS_TOPIC_ARN" \
  --protocol email \
  --notification-endpoint "YOUR_EMAIL_ADDRESS" \
  --region ap-northeast-1
```

登録したメールアドレスに届く確認メールで **Confirm subscription** を選択してください。確認が完了するまでSNS通知は配信されません。

購読状態の確認:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$SNS_TOPIC_ARN" \
  --region ap-northeast-1
```

---

## Step 8. FIS 実験テンプレート ID を確認する

```bash
cd terraform/environments/dev

# 状態を更新
terraform refresh

# すべての出力を確認
terraform output
```

期待される出力:

```
cluster_endpoint = "https://XXXXX.eks.ap-northeast-1.amazonaws.com"
cluster_name = "eks-chaos-postmortem-dev"
cpu_stress_experiment_template_id = "EXTAK1234567890"
network_latency_experiment_template_id = "EXTAB1234567890"
node_termination_experiment_template_id = "EXTAC1234567890"
pod_kill_experiment_template_id = "EXTAD1234567890"
s3_reports_bucket = "eks-chaos-postmortem-generator-reports-123456789012-dev"
sns_topic_arn = "arn:aws:sns:ap-northeast-1:123456789012:eks-chaos-postmortem-generator-postmortem-notifications-dev"
```

### 環境変数に設定（推奨）

Step 9 で実験を実行する際に便利なよう、環境変数に設定します：

```bash
export POD_KILL_TEMPLATE=$(terraform output -raw pod_kill_experiment_template_id)
export NODE_TERMINATION_TEMPLATE=$(terraform output -raw node_termination_experiment_template_id)
export NETWORK_LATENCY_TEMPLATE=$(terraform output -raw network_latency_experiment_template_id)
export CPU_STRESS_TEMPLATE=$(terraform output -raw cpu_stress_experiment_template_id)

# 確認
echo "Pod Kill: $POD_KILL_TEMPLATE"
echo "Node Termination: $NODE_TERMINATION_TEMPLATE"
echo "Network Latency: $NETWORK_LATENCY_TEMPLATE"
echo "CPU Stress: $CPU_STRESS_TEMPLATE"
```

---

## Step 9. 最初の実験を実行する

最初は `pod-kill` が一番わかりやすいです。Kubernetes の自己修復と、その後ろで AI ポストモーテム生成が走る全体像を確認できます。

### 9-1. Pod Kill 実験を開始

```bash
# 実験を開始して、ID を環境変数に保存
EXPERIMENT_ID=$(aws fis start-experiment \
  --experiment-template-id $POD_KILL_TEMPLATE \
  --region ap-northeast-1 \
  --query 'experiment.id' \
  --output text)

echo "Started experiment: $EXPERIMENT_ID"
```

### 9-2. 実験状態を監視

```bash
# リアルタイムで実験状態を確認（別ターミナル）
watch -n 5 "aws fis get-experiment --id $EXPERIMENT_ID --region ap-northeast-1 --query 'experiment.state'"

# 期待すること：
# - status: "initiating" → "running" → "completed"
# - failed の場合は「よくある詰まりどころ」を参照
```

### 9-3. Kubernetes 側の変化を監視

別ターミナルで実行:

```bash
kubectl get pods -n chaos-target -w

# 期待すること：
# - 既存 Pod が削除される（status が Terminating になる）
# - ReplicaSet によって新しい Pod が作成される
# - 数秒～数分で全 Pod が Running に戻る
```

### 9-4. 実験前後のターゲット確認

実験開始前に、ターゲットが正しく解決されるか確認:

```bash
# Pod に chaos-target=pod-kill ラベルがあるか確認
kubectl get pods -n chaos-target --show-labels

# FIS テンプレートのターゲット定義を確認
aws fis get-experiment-template \
  --id $POD_KILL_TEMPLATE \
  --region ap-northeast-1 \
  --output json | jq '.experimentTemplate.targets'
```

期待される出力例:

```json
{
  "chaos-target-pods": {
    "resourceType": "aws:eks:pod",
    "selectionMode": "ALL",
    "parameters": {
      "clusterIdentifier": "eks-chaos-postmortem-dev",
      "namespace": "chaos-target",
      "selectorType": "labelSelector",
      "selectorValue": "chaos-target=pod-kill"
    }
  }
}
```

---

## Step 10. 実験完了後の検証

実験が `completed` 状態になったら、以下を順番に確認します。

### 10-1. 実験状態の最終確認

```bash
aws fis get-experiment \
  --id $EXPERIMENT_ID \
  --region ap-northeast-1 \
  --query 'experiment.state'

# 期待すること:
# {
#     "status": "completed",
#     "reason": "Experiment completed."
# }
```

### 10-2. Pod が復旧したか確認

```bash
# Pod が全て Running か確認
kubectl get pods -n chaos-target

# Pod の再起動回数を確認
kubectl describe pods -n chaos-target | grep -A 5 "Restart Count"

# Pod のイベント確認
kubectl get events -n chaos-target --sort-by='.lastTimestamp' | tail -10
```

### 10-3. Step Functions 実行確認

```bash
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:ap-northeast-1:<account_id>:stateMachine:eks-chaos-postmortem-generator-postmortem-workflow-dev \
  --max-results 5 \
  --region ap-northeast-1
```

さらに詳細を見る場合:

```bash
aws stepfunctions describe-execution \
  --execution-arn <execution_arn> \
  --region ap-northeast-1
```

### 10-2. Lambda ログ確認

順番に追うなら次を確認します。

```bash
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-fis-event-handler-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-data-collector-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-bedrock-analyzer-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-report-formatter-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-notifier-dev --follow --region ap-northeast-1
```

### 10-3. S3 レポート確認

```bash
aws s3 ls s3://eks-chaos-postmortem-generator-reports-<account_id>-dev/reports/ --recursive --region ap-northeast-1
```

見つかったレポートに対して URL を再発行する場合:

```bash
aws s3 presign \
  s3://eks-chaos-postmortem-generator-reports-<account_id>-dev/reports/<experiment_type>/<experiment_id>/postmortem.html \
  --expires-in 604800 \
  --region ap-northeast-1
```

### 10-4. Amazon SNS 通知確認

実験完了から3〜5分程度で、購読確認済みのメールアドレスにSNS通知が届く想定です。

メッセージ内で確認したい内容:

- 実験 ID
- 実験種別
- AI が生成した概要
- 根本原因
- レポート URL

### 10-5. 全体検証スクリプト

以下を実行して、全体の検証を一度に行えます:

```bash
#!/bin/bash

echo "=== 1. 実験状態 ==="
aws fis get-experiment --id $EXPERIMENT_ID --region ap-northeast-1 --query 'experiment.state'

echo ""
echo "=== 2. Pod 状態 ==="
kubectl get pods -n chaos-target -o wide

echo ""
echo "=== 3. Step Functions 実行状況 ==="
aws stepfunctions list-executions \
  --state-machine-arn arn:aws:states:ap-northeast-1:999828867039:stateMachine:eks-chaos-postmortem-generator-postmortem-workflow-dev \
  --max-results 1 \
  --region ap-northeast-1 \
  --query 'executions[0].[status, startDate]'

echo ""
echo "=== 4. Lambda 実行回数（最新） ==="
for lambda in fis-event-handler data-collector bedrock-analyzer report-formatter notifier; do
  echo -n "$lambda: "
  aws logs describe-log-streams \
    --log-group-name /aws/lambda/eks-chaos-postmortem-generator-${lambda}-dev \
    --region ap-northeast-1 \
    --query 'logStreams[0].lastEventTimestamp' \
    --output text
done

echo ""
echo "=== 5. S3 レポート（最新3件） ==="
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="eks-chaos-postmortem-generator-reports-${ACCOUNT_ID}-dev"
aws s3 ls s3://$BUCKET/reports/ --recursive --region ap-northeast-1 | tail -3

echo ""
echo "=== 6. CloudWatch ダッシュボード ==="
aws cloudwatch get-dashboard \
  --dashboard-name eks-chaos-postmortem-generator-chaos-dashboard-dev \
  --region ap-northeast-1 \
  --query 'DashboardName' \
  --output text
```

実行:

```bash
bash check_experiment.sh
```

---

## Step 11. 追加で試せる実験

### Node Termination

```bash
aws fis start-experiment \
  --experiment-template-id $NODE_TERMINATION_TEMPLATE \
  --region ap-northeast-1
```

見どころ:

- `chaos` ノードグループだけが対象になるか
- Pod が再スケジューリングされるか
- Karpenter による自動ノード再構築

### Network Latency（Chaos Mesh ベース）

```bash
aws fis start-experiment \
  --experiment-template-id $NETWORK_LATENCY_TEMPLATE \
  --region ap-northeast-1
```

見どころ:

- 60 秒間の 100ms 遅延注入
- Chaos Mesh の NetworkChaos リソースが実際に created されるか
- 劣化イベント（遅延増加）がポストモーテムにどう反映されるか

### CPU Stress（Chaos Mesh ベース）

```bash
aws fis start-experiment \
  --experiment-template-id $CPU_STRESS_TEMPLATE \
  --region ap-northeast-1
```

見どころ:

- 60 秒間の CPU 80% ストレス注入
- Chaos Mesh の StressChaos リソースが実際に created されるか
- CPU メトリクス上昇
- StopCondition（CPU 90%）がどう反応するか

---

## よくある詰まりどころ

### FIS 実験が「Error resolving targets」で失敗する

確認ポイント（この順番で確認）:

1. **Pod ラベルが正しいか**
   ```bash
   kubectl get pods -n chaos-target --show-labels
   # chaos-target=pod-kill ラベルが表示されるはず
   ```
   表示されない場合:
   ```bash
   kubectl apply -f k8s/sample-app/deployment.yaml
   kubectl wait --for=condition=Ready pod -l app=sample-app -n chaos-target --timeout=300s
   ```

2. **IAM ポリシーに必要な権限があるか**
   ```bash
   aws iam get-role-policy \
     --role-name eks-chaos-postmortem-generator-fis-execution-role-dev \
     --policy-name eks-chaos-postmortem-generator-fis-execution-policy-dev \
     --output json | jq '.PolicyDocument.Statement[] | {Sid, Action}'
   ```
   以下の権限が必須:
   - `eks:DescribeCluster`, `eks:ListNodegroups`, `eks:DescribeNodegroup`, `eks:AccessKubernetesApi`
   - `ec2:DescribeInstances`
   - `cloudwatch:DescribeAlarms`

3. **aws-auth ConfigMap が正しく設定されているか**
   ```bash
   kubectl get configmap aws-auth -n kube-system -o yaml
   ```
   `mapRoles` に以下が含まれているか確認:
   ```yaml
   - rolearn: arn:aws:iam::999828867039:role/eks-chaos-postmortem-generator-fis-execution-role-dev
     username: system:serviceaccount:chaos-target:fis-sa
     groups:
       - system:authenticated
   ```

4. **Kubernetes RBAC 権限が設定されているか**
   ```bash
   kubectl get clusterrolebinding | grep fis
   # fis-pod-delete と fis-chaos-mesh が表示されるはず
   
   kubectl auth can-i delete pods --as=system:serviceaccount:chaos-target:fis-sa -n chaos-target
   # yes が返されるはず
   ```

5. **FIS テンプレートのターゲット定義が正しいか**
   ```bash
   aws fis get-experiment-template \
     --id <pod_kill_experiment_template_id> \
     --region ap-northeast-1 \
     --output json | jq '.experimentTemplate.targets'
   ```
   以下が含まれているか確認:
   - `clusterIdentifier`: `eks-chaos-postmortem-dev`
   - `namespace`: `chaos-target`
   - `selectorType`: `labelSelector`
   - `selectorValue`: `chaos-target=pod-kill`

### Network Latency / CPU Stress 実験で失敗する

確認ポイント:

- EKSクラスターに Chaos Mesh がインストール済みか
  ```bash
  kubectl get ns | grep chaos-mesh
  kubectl get pods -n chaos-mesh-system
  ```
- Chaos Mesh の CRD が登録済みか
  ```bash
  kubectl get crd | grep chaos-mesh
  ```
- FIS 用 ServiceAccount が `chaos-target` namespace に存在するか: `kubectl get sa -n chaos-target`
- RBAC 権限が正しく設定されているか: `kubectl get clusterrolebinding | grep fis`

### Bedrock 呼び出しで失敗する

確認ポイント:

- 東京リージョンで Claude Sonnet 4.6 が使えるか
- 対象モデルへのアクセスが許可されているか

### Amazon SNS 通知が来ない

確認ポイント:

- メール購読が `PendingConfirmation` のままになっていないか
- notifier Lambda の環境変数 `SNS_TOPIC_ARN` が正しいか
- notifier Lambda のログに `SNS送信完了` が記録されているか

### Pod Kill 実験で Pod が削除されない

確認ポイント:

- `chaos-target` namespace の Pod に `chaos-target: pod-kill` ラベルが付与されているか
- FIS 用 ServiceAccount `fis-sa` が存在するか: `kubectl get sa -n chaos-target`
- Pod Delete の ClusterRole / ClusterRoleBinding が設定されているか: `kubectl get clusterrolebinding | grep fis-pod-delete`

### Kubernetes イベントが十分に取れない

このリポジトリの現状では、Lambda パッケージングに依存追加の改善余地があります。詳しくは [ARCHITECTURE.md](ARCHITECTURE.md) の「実装上の注意点と現状ギャップ」を参照してください。

### `terraform plan` は通るのに動作が怪しい

このプロジェクトは AWS サービス連携が多いため、Terraform 成功だけでは完了ではありません。必ず次も実施してください。

- `kubectl get pods -n chaos-target --show-labels`
- `kubectl get sa -n chaos-target`
- `aws fis start-experiment`
- `aws stepfunctions list-executions`
- `aws s3 ls .../reports/`

---

## コスト管理

月次見積もりは約 **$109** です。大半は EKS クラスター固定費です。

検証を終えたら、まずノードを止めるだけでもコストを下げられます。

```bash
aws eks update-nodegroup-config \
  --cluster-name eks-chaos-postmortem-dev \
  --nodegroup-name eks-chaos-postmortem-generator-baseline-dev \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region ap-northeast-1

aws eks update-nodegroup-config \
  --cluster-name eks-chaos-postmortem-dev \
  --nodegroup-name eks-chaos-postmortem-generator-chaos-dev \
  --scaling-config minSize=0,maxSize=2,desiredSize=0 \
  --region ap-northeast-1
```

---

## クリーンアップ

完全に片付ける場合は、まず S3 レポートを消してから Terraform destroy を行います。

### 1. レポートバケットを空にする

```bash
BUCKET="eks-chaos-postmortem-generator-reports-$(aws sts get-caller-identity --query Account --output text)-dev"
aws s3 rm s3://$BUCKET --recursive --region ap-northeast-1
```

### 2. Terraform destroy

```bash
cd terraform/environments/dev
terraform destroy -var-file="terraform.tfvars"
cd ../../..
```

SNSトピックとメール購読は `terraform destroy` により削除されます。

---

## ポートフォリオとしての見どころ

- Chaos Engineering の実験実行だけでなく、分析と共有まで自動化している
- FIS / EventBridge / Step Functions / Lambda / Bedrock を横断したイベント駆動設計になっている
- 冪等性、最小権限 IAM、StopCondition、可観測性など、SRE 的な安全設計を入れている
- AI 出力を 6 項目の構造化 JSON に制約し、レポートとして再利用しやすくしている

---

## ライセンス

MIT License
