# eks-chaos-postmortem-generator

> Chaos Engineering × AI — 障害を意図的に起こし、AIが人間より先にポストモーテムを書く

AWS Fault Injection Service（FIS）で EKS クラスターに意図的な障害を注入し、Amazon Bedrock が自動でポストモーテムを生成して Chatwork に通知する SRE プラットフォームです。

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
② bedrock-analyzer → Claude Sonnet 3.5 でポストモーテム生成（6項目バリデーション）
③ report-formatter → HTMLレポート生成 → S3保存 → presigned URL
④ notifier         → Chatwork通知
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
| AI | Amazon Bedrock（Claude Sonnet 3.5） |
| イベント駆動 | Amazon EventBridge |
| ストレージ | Amazon S3, Amazon DynamoDB |
| 通知 | Chatwork API |
| 可観測性 | CloudWatch, X-Ray, Lambda Powertools |
| CI/CD | GitHub Actions + OIDC |

---

## このハンズオンでできること

この README の手順を完了すると、次の流れを実際に確認できます。

1. Terraform で EKS / FIS / Lambda / Step Functions / S3 / EventBridge を構築する
2. `chaos-target` namespace にサンプルアプリを配置する
3. FIS 実験を 1 つ実行する
4. EventBridge から Step Functions が起動し、AI ポストモーテムが生成されることを確認する
5. Chatwork と S3 にレポートが出力されることを確認する

---

## 前提条件

以下を事前に用意してください。

- AWS アカウント
- `ap-northeast-1` で EKS / FIS / Bedrock / Step Functions / Lambda / Secrets Manager / CloudWatch が利用可能であること
- AWS CLI インストール済み
- Terraform `>= 1.6`
- `kubectl`
- Git
- Chatwork アカウント、API キー、通知先 Room ID
- Bedrock で `Claude 3.5 Sonnet` を利用できること

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

Claude Sonnet 3.5 へのアクセスがないと、ポストモーテム生成は最後まで成功しません。

```bash
aws bedrock list-foundation-models --region ap-northeast-1
```

### 4. Chatwork の情報を準備する

必要な値:

- `api_key`
- `room_id`

`room_id` は Chatwork の URL の `#!rid` 以降の数値です。

---

## ハンズオン全体像

この README では次の順番で進めます。

1. Terraform バックエンド用 S3 バケットを作る
2. `terraform.tfvars` を設定する
3. Terraform でインフラを構築する
4. Chatwork シークレットを登録する
5. EKS に接続してサンプルアプリをデプロイする
6. FIS 実験を実行する
7. Step Functions / S3 / Chatwork で結果を確認する
8. 必要に応じてコスト削減またはクリーンアップする

---

## Step 1. Terraform バックエンドを準備する

このプロジェクトは Terraform state を S3 バックエンドに保存します。まず state 用バケットを作成します。

```bash
aws s3 mb s3://eks-chaos-postmortem-tfstate --region ap-northeast-1
```

確認:

```bash
aws s3 ls s3://eks-chaos-postmortem-tfstate --region ap-northeast-1
```

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
- Secrets Manager シークレット

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

作業が終わったら、プロジェクトルートへ戻ります。

```bash
cd ../../..
```

---

## Step 4. Chatwork シークレットを登録する

Terraform により Secrets Manager のシークレット本体は作成されますが、中身は手動登録です。

```bash
aws secretsmanager put-secret-value \
  --secret-id "eks-chaos-postmortem-generator/chatwork-api-key-dev" \
  --secret-string '{"api_key":"YOUR_CHATWORK_API_KEY","room_id":"YOUR_ROOM_ID"}' \
  --region ap-northeast-1
```

確認:

```bash
aws secretsmanager get-secret-value \
  --secret-id "eks-chaos-postmortem-generator/chatwork-api-key-dev" \
  --region ap-northeast-1
```

注意:

- シークレット名はコード上 `eks-chaos-postmortem-generator/chatwork-api-key-dev` です

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

## Step 6. サンプルアプリをデプロイする

Chaos 実験対象の namespace と Deployment を適用します。

```bash
kubectl apply -f k8s/sample-app/namespace.yaml
kubectl apply -f k8s/sample-app/deployment.yaml
```

状態確認:

```bash
kubectl get pods -n chaos-target
kubectl get pods -n chaos-target -w
```

期待すること:

- `sample-app` の Pod が 3 つ起動する
- `Running` になる

追加確認:

```bash
kubectl describe deployment sample-app -n chaos-target
kubectl get nodes --show-labels | grep chaos-target
```

---

## Step 7. FIS 実験テンプレート ID を確認する

```bash
cd terraform/environments/dev
terraform output
cd ../../..
```

確認したい値:

- `pod_kill_experiment_template_id`
- `node_termination_experiment_template_id`
- `network_latency_experiment_template_id`
- `cpu_stress_experiment_template_id`

---

## Step 8. 最初の実験を実行する

最初は `pod-kill` が一番わかりやすいです。Kubernetes の自己修復と、その後ろで AI ポストモーテム生成が走る全体像を確認できます。

### 8-1. Pod Kill 実験

```bash
aws fis start-experiment \
  --experiment-template-id <pod_kill_experiment_template_id> \
  --region ap-northeast-1
```

### 8-2. Kubernetes 側の変化を監視

別ターミナルで実行:

```bash
kubectl get pods -n chaos-target -w
```

期待すること:

- 既存 Pod が削除される
- ReplicaSet によって新しい Pod が再作成される
- 数分以内に再び 3 Pod が `Running` へ戻る

---

## Step 9. ポストモーテム生成を確認する

### 9-1. Step Functions 実行確認

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

### 9-2. Lambda ログ確認

順番に追うなら次を確認します。

```bash
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-fis-event-handler-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-data-collector-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-bedrock-analyzer-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-report-formatter-dev --follow --region ap-northeast-1
aws logs tail /aws/lambda/eks-chaos-postmortem-generator-notifier-dev --follow --region ap-northeast-1
```

### 9-3. S3 レポート確認

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

### 9-4. Chatwork 通知確認

実験完了から 3〜5 分程度で、Chatwork の指定ルームに通知が届く想定です。

メッセージ内で確認したい内容:

- 実験 ID
- 実験種別
- AI が生成した概要
- 根本原因
- レポート URL

---

## 追加で試せる実験

### Node Termination

```bash
aws fis start-experiment \
  --experiment-template-id <node_termination_experiment_template_id> \
  --region ap-northeast-1
```

見どころ:

- `chaos` ノードグループだけが対象になるか
- Pod が再スケジューリングされるか

### Network Latency

```bash
aws fis start-experiment \
  --experiment-template-id <network_latency_experiment_template_id> \
  --region ap-northeast-1
```

見どころ:

- 60 秒間の遅延注入
- 劣化イベントがポストモーテムにどう反映されるか

### CPU Stress

```bash
aws fis start-experiment \
  --experiment-template-id <cpu_stress_experiment_template_id> \
  --region ap-northeast-1
```

見どころ:

- CPU 使用率上昇
- StopCondition やメトリクス変化

---

## よくある詰まりどころ

### Bedrock 呼び出しで失敗する

確認ポイント:

- 東京リージョンで Claude Sonnet 3.5 が使えるか
- 対象モデルへのアクセスが許可されているか

### Chatwork 通知が来ない

確認ポイント:

- Secrets Manager のシークレット名が正しいか
- `api_key` と `room_id` の JSON キー名が正しいか
- notifier Lambda のログにエラーが出ていないか

### Kubernetes イベントが十分に取れない

このリポジトリの現状では、Lambda パッケージングに依存追加の改善余地があります。詳しくは [ARCHITECTURE.md](ARCHITECTURE.md) の「実装上の注意点と現状ギャップ」を参照してください。

### `terraform plan` は通るのに動作が怪しい

このプロジェクトは AWS サービス連携が多いため、Terraform 成功だけでは完了ではありません。必ず次も実施してください。

- `kubectl get pods -n chaos-target`
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

### 3. 必要ならシークレットを削除

```bash
aws secretsmanager delete-secret \
  --secret-id "eks-chaos-postmortem-generator/chatwork-api-key-dev" \
  --force-delete-without-recovery \
  --region ap-northeast-1
```

---

## ポートフォリオとしての見どころ

- Chaos Engineering の実験実行だけでなく、分析と共有まで自動化している
- FIS / EventBridge / Step Functions / Lambda / Bedrock を横断したイベント駆動設計になっている
- 冪等性、最小権限 IAM、StopCondition、可観測性など、SRE 的な安全設計を入れている
- AI 出力を 6 項目の構造化 JSON に制約し、レポートとして再利用しやすくしている

---

## ライセンス

MIT License
