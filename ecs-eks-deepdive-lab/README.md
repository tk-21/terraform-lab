# ECS/EKS Deep Dive Lab

FastAPI ジョブ API + SQS Worker という**同一ワークロード**を ECS と EKS の両方にデプロイし、スケーリング挙動・運用手順・コストを**実測データで比較**するハンズオンラボ。

---

## このハンズオンで得られること

### 表面的な理解を超えた ECS の実力

| 表面的なレベル | このラボで到達するレベル |
|--------------|----------------------|
| "Fargate を使ったことがある" | **Capacity Provider の base/weight 計算式**を説明できる。6 タスク時の Fargate/Spot 内訳を即答できる |
| "Service Discovery を知っている" | **Service Connect**（Envoy サイドカー自動注入）と旧来の Cloud Map DNS の違い、Retry/Circuit Breaker が無料で使える理由を説明できる |
| "スケーリングを設定した" | **CloudWatch Alarm → Step Scaling** の評価周期がスケールアウト速度のボトルネックになる理由を実測値で語れる |
| "ログを見たことがある" | **ECS Exec**（SSM Session Manager の仕組み）を使ってライブデバッグできる |
| "Spot を使ったことがある" | **SIGTERM ハンドラー + stopTimeout** で Spot 中断時のメッセージロストを防ぐコードを書ける |

### 表面的な理解を超えた EKS の実力

| 表面的なレベル | このラボで到達するレベル |
|--------------|----------------------|
| "Cluster Autoscaler を知っている" | **Karpenter** の NodePool disruption budget・consolidation を設定し、CA との速度差を実測で証明できる |
| "OIDC IRSA を使ったことがある" | **Pod Identity**（2023 年 GA の新方式）の仕組みと IRSA との違いを設計根拠込みで説明できる |
| "HPA を設定したことがある" | **KEDA の SQS キュー深度トリガー**で minReplicaCount=0 のゼロスケールを実現し、ECS との比較コストを語れる |
| "Deployment を書いたことがある" | **topologySpreadConstraints** で AZ 分散を明示制御し、**PDB** と Karpenter consolidation budget の連携を説明できる |

### 定量データによる比較力

```
ロードテスト後に手元の数値で語れるようになる:

  ECS スケールアウト開始まで: 約 60〜90 秒
    理由: CloudWatch Alarm 評価周期 60 秒 + Step Scaling 反映

  EKS スケールアウト開始まで: 約 15〜45 秒
    理由: KEDA 15 秒ポーリング + Karpenter ノード起動

  EKS の KEDA minReplicaCount=0 → 静穏時の Worker EC2 コスト = ¥0
```

面接で「ECS と EKS、どちらを選ぶか？なぜか？」と問われたとき、**自分が動かしたシステムの実測値を根拠に即答**できるエンジニアになることがゴール。

---

## アーキテクチャ概要

```
Internet
    │
    ├─────────────────────┬─────────────────────────
    │                     │
    ▼                     ▼
[ECS ALB]            [EKS ALB (AWS LBC が作成)]
    │                     │
    ▼                     ▼
[ECS Cluster]        [EKS Cluster (K8s 1.30)]
  API: Fargate + Spot    API: Karpenter Spot arm64
  Worker: Fargate Spot   Worker: KEDA minReplicas=0
    │                     │
    └──────────┬───────────┘
               │
        [SQS: deepdive-job-queue]  (共通)
        [ECR: api-server, job-worker]  (共通)
        [VPC Endpoints × 10]  (ECR/SQS/SSM/CWLogs/STS/EC2)
```

**ハイライト設計:**
- ECS: `base=1, weight=4` で Fargate 最低 1 台保証 + Spot 最大活用
- EKS: Karpenter が Pod 要件から直接 EC2 を選択（Cluster Autoscaler 不要）
- 共通: NAT Gateway 1 台のみ + VPC Endpoint で通信コストを最小化

---

## 前提条件

### 必要なツール

```bash
# バージョン確認
aws --version          # AWS CLI v2
terraform version      # >= 1.6
docker buildx version  # arm64 クロスコンパイル用
kubectl version        # Phase 3 から使用
helm version           # Phase 3 から使用
jq --version           # JSON パース用
```

### 必要な権限

以下の権限を持つ IAM ユーザー/ロールで実行すること:
- VPC・EC2・ECS・EKS・ECR・SQS・SSM・IAM・CloudWatch の管理権限

```bash
# 認証確認
aws sts get-caller-identity
```

### 推奨環境

- **リージョン**: ap-northeast-1（東京）固定
- **マシン**: arm64 ネイティブ（M1/M2 Mac 等）または `docker buildx` でクロスビルド可能な環境
- **想定費用**: 約 $5〜10（全フェーズ実施 + 即日クリーンアップの場合）

> **NAT Gateway が 1 台起動するため、放置するとコストが発生します。**  
> Phase 5 のクリーンアップを必ず実施してください。

---

## フェーズ構成

| Phase | 内容 | 所要時間 |
|-------|------|---------|
| [Phase 1](#phase-1-共通インフラ構築--アプリビルド) | 共通インフラ（VPC/SQS/ECR）+ Docker ビルド | 約 30 分 |
| [Phase 2](#phase-2-ecs-deep-dive) | ECS Fargate + Service Connect + ECS Exec | 約 45 分 |
| [Phase 3](#phase-3-eks-deep-dive) | EKS + Karpenter + KEDA + Pod Identity | 約 60 分 |
| [Phase 4](#phase-4-可観測性--ロードテスト) | CloudWatch Dashboard + ロードテスト + 定量比較 | 約 30 分 |
| [Phase 5](#phase-5-adr--クリーンアップ) | ADR 執筆 + 口頭説明チェック + リソース削除 | 約 20 分 |

---

## Phase 1: 共通インフラ構築 + アプリビルド

**目標**: ECS/EKS 両方が使う VPC・SQS・ECR を Terraform で構築し、コンテナイメージを ECR へ push する。

### 前提確認

```bash
cd ecs-eks-deepdive-lab

aws sts get-caller-identity          # 認証確認
terraform version                    # >= 1.6 であること
docker buildx inspect                # arm64 ビルド可能か確認
```

### Step 1-1: Foundation を apply する

```bash
cd terraform/foundation
terraform init
terraform plan -out=tfplan
```

plan の出力を確認して問題なければ apply を実行する:

```bash
terraform apply tfplan
```

**作成されるリソース:**

| リソース | 名前/内容 |
|---------|---------|
| VPC | `10.0.0.0/16`、DNS ホスト名有効 |
| Public Subnet | `10.0.0.0/24`(1a), `10.0.1.0/24`(1c) |
| Private Subnet | `10.0.128.0/24`(1a), `10.0.129.0/24`(1c) |
| NAT Gateway | 1 台のみ（1a）|
| VPC Endpoint (Interface) | ECR API/DKR, CloudWatch Logs, SSM, SSMMESSAGES, EC2MESSAGES, STS, SQS, EC2 |
| VPC Endpoint (Gateway) | S3 |
| SQS キュー | `deepdive-job-queue` (visibility: 300s) + `deepdive-job-dlq` (14日保持) |
| ECR リポジトリ | `api-server`, `job-worker` |
| IAM ロール | ECS 実行ロール、ECS タスクロール、EKS ノードロール |
| SSM Parameter | `/deepdive/sqs-queue-url` |

### Step 1-2: アプリコンテナをビルドして ECR へ push する

Foundation の出力から ECR URL を取得する:

```bash
ACCOUNT_ID=$(terraform output -raw aws_account_id)
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.ap-northeast-1.amazonaws.com"
ECR_API=$(terraform output -raw ecr_api_url)
ECR_WORKER=$(terraform output -raw ecr_worker_url)

echo "ECR API:    $ECR_API"
echo "ECR Worker: $ECR_WORKER"
```

ECR へログインする:

```bash
aws ecr get-login-password --region ap-northeast-1 | \
  docker login --username AWS --password-stdin "${ECR_REGISTRY}"
```

arm64 イメージをビルドして push する:

```bash
# API Server
docker buildx build \
  --platform linux/arm64 \
  --tag "${ECR_API}:latest" \
  ../../app/api/ \
  --push

# Job Worker
docker buildx build \
  --platform linux/arm64 \
  --tag "${ECR_WORKER}:latest" \
  ../../app/worker/ \
  --push
```

> **x86_64 マシンで `--platform linux/arm64` が使えない場合:**
> ```bash
> docker buildx create --use   # QEMU エミュレーターを使ったビルダーを作成
> ```

### Step 1-3: Phase 1 の動作確認

```bash
# VPC Endpoint が 10 件（Interface 9 + Gateway 1）あること
VPC_ID=$(terraform output -raw vpc_id)
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'VpcEndpoints[*].ServiceName' \
  --output table

# SQS キューが 2 件あること
aws sqs list-queues --queue-name-prefix deepdive

# ECR にイメージが push されていること
aws ecr describe-images --repository-name api-server \
  --query 'imageDetails[*].{tag:imageTags[0],pushed:imagePushedAt}'

# SSM パラメータが存在すること
aws ssm get-parameters-by-path --path /deepdive/
```

**Phase 1 完了チェック:**
- [ ] `terraform apply` がエラーなく完了
- [ ] VPC Endpoint が 10 件確認できる
- [ ] SQS キューが 2 件（job-queue + job-dlq）ある
- [ ] ECR に `api-server:latest` と `job-worker:latest` がある

---

## Phase 2: ECS Deep Dive

**目標**: ECS の「使ったことがある」を超え、Capacity Provider・Service Connect・ECS Exec を実体験として語れるようにする。

### Step 2-1: ECS インフラを apply する

```bash
cd ../../terraform/ecs   # ecs-eks-deepdive-lab/terraform/ecs
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**作成されるリソース:**

| リソース | 詳細 |
|---------|------|
| ECS Cluster | `deepdive-ecs`、Container Insights 有効 |
| Capacity Providers | FARGATE (base=1, weight=1) + FARGATE_SPOT (base=0, weight=4) |
| ALB | Public Subnet、ポート 80 |
| API Service | desired=2、Service Connect 有効、ECS Exec 有効 |
| Worker Service | desired=1、FARGATE_SPOT 100%、stopTimeout=30s |
| Step Scaling | SQS 深度 ≥10 で +2 タスク、≥50 で +5 タスク |
| CloudWatch Alarms | スケールアウト(60s評価), スケールイン(2分継続) |

### Step 2-2: 基本動作確認

ALB の DNS 名を取得する:

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)
echo "ECS ALB: http://${ALB_DNS}"

# ヘルスチェック
curl -s "http://${ALB_DNS}/health" | python3 -m json.tool
# → {"status": "ok"}

# ジョブ送信
curl -s -X POST "http://${ALB_DNS}/jobs" \
  -H "Content-Type: application/json" \
  -d '{"payload": "phase2-test-001"}' | python3 -m json.tool
# → {"job_id": "...", "status": "queued"}
```

### Step 2-3: Capacity Provider の分配を確認する【深掘りポイント①】

タスクがどちらのプロバイダーで起動しているか確認する:

```bash
TASK_ARNS=$(aws ecs list-tasks --cluster deepdive-ecs --output text --query 'taskArns[*]')

aws ecs describe-tasks \
  --cluster deepdive-ecs \
  --tasks ${TASK_ARNS} \
  --query 'tasks[*].{id:taskArn,provider:capacityProviderName,status:lastStatus}' \
  --output table
```

> **理解チェック**: desired=2 で FARGATE:1 / FARGATE_SPOT:1 になっているか？  
> `base=1` で最初の 1 タスクを Fargate が担保し、残りを `weight=1:4` で分配するため。

### Step 2-4: ECS Exec でコンテナ内に入る【深掘りポイント②】

ECS Exec は SSM Session Manager 経由でコンテナ内シェルに接続する機能。IAM の `ssmmessages:*` 権限と VPC の `ssmmessages` Endpoint が事前に必要（Phase 1 で設定済み）。

```bash
CLUSTER="deepdive-ecs"

# 実行中タスクの ARN を取得
TASK_ARN=$(aws ecs list-tasks \
  --cluster ${CLUSTER} \
  --service-name deepdive-api \
  --query 'taskArns[0]' \
  --output text)

echo "接続先: ${TASK_ARN}"

# コンテナ内シェルを起動
aws ecs execute-command \
  --cluster ${CLUSTER} \
  --task ${TASK_ARN} \
  --container api \
  --interactive \
  --command "/bin/sh"
```

シェル内で確認すること:

```sh
# SQS_QUEUE_URL が SSM から注入されているか
env | grep SQS

# Service Connect が動いているか（PID 確認）
ps aux  # envoy プロセスが見えるはず

# initProcessEnabled で PID 1 が init になっているか
cat /proc/1/cmdline

exit
```

### Step 2-5: スケーリングを観察する【深掘りポイント③】

SQS に 50 メッセージを送信して Step Scaling の発動を確認する:

```bash
SQS_URL=$(cd ../foundation && terraform output -raw sqs_queue_url)

# 50 メッセージを送信
for i in $(seq 1 50); do
  aws sqs send-message \
    --queue-url "${SQS_URL}" \
    --message-body "load-test-${i}" \
    --message-attributes \
      "{\"job_id\":{\"StringValue\":\"t${i}\",\"DataType\":\"String\"}}" \
    > /dev/null
done
echo "50 メッセージ送信完了"

# Worker タスク数の変化を 30 秒ごとに監視
watch -n 30 "aws ecs describe-services \
  --cluster deepdive-ecs \
  --services deepdive-worker \
  --query 'services[0].{desired:desiredCount,running:runningCount,pending:pendingCount}'"
```

**記録しておく数値（Phase 4 比較用）:**
- CloudWatch Alarm 発火からタスク増加まで: _____ 秒
- タスクが PENDING → RUNNING になるまで: _____ 秒

**Phase 2 完了チェック:**
- [ ] `http://<ALB>/health` が 200 を返す
- [ ] `/jobs` でジョブを送信でき、SQS にメッセージが入る
- [ ] ECS Exec でコンテナ内シェルに入れた
- [ ] タスクの Capacity Provider が FARGATE と FARGATE_SPOT に分かれている
- [ ] 50 メッセージ送信でワーカーのタスク数が増加した

---

## Phase 3: EKS Deep Dive

**目標**: Karpenter・Pod Identity・KEDA を実体験として語れるようにする。ECS との比較ができる状態にする。

### 前提確認

```bash
kubectl version   # インストール済みか確認
helm version      # インストール済みか確認
```

### Step 3-1: EKS クラスターを apply する

```bash
cd ../eks   # ecs-eks-deepdive-lab/terraform/eks
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

**作成されるリソース:**

| リソース | 詳細 |
|---------|------|
| EKS Cluster | `deepdive-eks`、バージョン 1.30、認証モード API |
| System Node Group | `t4g.medium`(arm64)、desired=2、CriticalAddonsOnly Taint |
| EKS Addons | vpc-cni (Prefix Delegation), coredns, kube-proxy, eks-pod-identity-agent |
| Pod Identity Roles | LBC, KEDA, api-server, job-worker, cloudwatch-agent |
| Karpenter IAM Role | `deepdive-karpenter-ctrl` |
| Karpenter Interrupt Queue | EventBridge → SQS で Spot 割り込み通知を受信 |

apply 後に kubeconfig を更新する:

```bash
aws eks update-kubeconfig --name deepdive-eks --region ap-northeast-1

# ノードが起動していることを確認（2〜3 分かかる）
kubectl get nodes
# NAME                                            STATUS   ROLES    AGE
# ip-10-0-128-xxx.ap-northeast-1.compute.internal Ready    <none>   2m
```

### Step 3-2: Karpenter をインストールする

```bash
KARPENTER_VERSION="1.0.0"   # https://github.com/aws/karpenter/releases で最新版を確認
CLUSTER_NAME="deepdive-eks"

helm upgrade --install karpenter \
  oci://public.ecr.aws/karpenter/karpenter \
  --version "${KARPENTER_VERSION}" \
  --namespace karpenter \
  --create-namespace \
  --set settings.clusterName="${CLUSTER_NAME}" \
  --set settings.interruptionQueue="deepdive-karpenter-interrupt" \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.requests.memory=256Mi \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

# 起動確認
kubectl get pods -n karpenter
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=10
```

### Step 3-3: AWS Load Balancer Controller をインストールする

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm upgrade --install aws-load-balancer-controller \
  eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName=deepdive-eks \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Step 3-4: KEDA をインストールする

```bash
helm repo add kedacore https://kedacore.github.io/charts && helm repo update

helm upgrade --install keda kedacore/keda \
  --namespace keda \
  --create-namespace \
  --set tolerations[0].key=CriticalAddonsOnly \
  --set tolerations[0].operator=Exists \
  --wait

kubectl get pods -n keda
```

### Step 3-5: Karpenter NodePool を作成する

```bash
kubectl apply -f k8s/manifests/karpenter-nodepool.yaml

# NodePool と EC2NodeClass が作成されたことを確認
kubectl get nodepool
kubectl get ec2nodeclass
```

### Step 3-6: Kubernetes マニフェストのプレースホルダーを置換してデプロイする

Foundation の outputs から実際の値を取得する:

```bash
cd ../foundation   # terraform/foundation
ECR_API=$(terraform output -raw ecr_api_url)
ECR_WORKER=$(terraform output -raw ecr_worker_url)
SQS_URL=$(terraform output -raw sqs_queue_url)
PUBLIC_SUBNETS=$(terraform output -json public_subnet_ids | jq -r 'join(",")')
cd ../..   # ecs-eks-deepdive-lab/

echo "ECR_API:         ${ECR_API}"
echo "ECR_WORKER:      ${ECR_WORKER}"
echo "SQS_URL:         ${SQS_URL}"
echo "PUBLIC_SUBNETS:  ${PUBLIC_SUBNETS}"
```

プレースホルダーを実際の値に置換する:

```bash
# マニフェストのコピーを作成（元ファイルは書き換えない）
cp k8s/manifests/api.yaml    /tmp/api-deploy.yaml
cp k8s/manifests/worker.yaml /tmp/worker-deploy.yaml

sed -i \
  -e "s|<ECR_API_URL>|${ECR_API}|g" \
  -e "s|<SQS_QUEUE_URL>|${SQS_URL}|g" \
  -e "s|<PUBLIC_SUBNET_IDS>|${PUBLIC_SUBNETS}|g" \
  /tmp/api-deploy.yaml

sed -i \
  -e "s|<ECR_WORKER_URL>|${ECR_WORKER}|g" \
  -e "s|<SQS_QUEUE_URL>|${SQS_URL}|g" \
  /tmp/worker-deploy.yaml
```

デプロイする:

```bash
kubectl apply -f k8s/manifests/namespace.yaml
kubectl apply -f k8s/manifests/serviceaccounts.yaml
kubectl apply -f k8s/manifests/karpenter-nodepool.yaml
kubectl apply -f /tmp/api-deploy.yaml
kubectl apply -f /tmp/worker-deploy.yaml
```

### Step 3-7: Karpenter ノードプロビジョニングを観察する【深掘りポイント①】

Pod が Pending になると Karpenter が EC2 を起動する様子をリアルタイムで確認する:

```bash
# 別ターミナルで Pod の状態変化を監視
kubectl get pods -n deepdive --watch &

# Karpenter のログをリアルタイムで確認
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --follow &

# NodeClaim（Karpenter がノードを申請した記録）
kubectl get nodeclaim -o wide --watch
```

**記録しておく数値:**
- Pod Pending → Node Ready までの時間: _____ 秒
- Karpenter が選んだインスタンスタイプ: _____

### Step 3-8: EKS ALB の作成を確認する

AWS LBC が Ingress リソースを検知して ALB を自動作成する（2〜3 分かかる）:

```bash
kubectl get ingress -n deepdive --watch
# ADDRESS 列に ALB の DNS 名が現れるまで待つ

EKS_ALB=$(kubectl get ingress api-server -n deepdive \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "EKS ALB: http://${EKS_ALB}"

curl -s "http://${EKS_ALB}/health"
# → {"status": "ok"}
```

### Step 3-9: KEDA スケーリングを確認する【深掘りポイント②】

```bash
SQS_URL=$(cd terraform/foundation && terraform output -raw sqs_queue_url)

# 30 メッセージを送信（queueLength=5 なので 6 レプリカに増えるはず）
for i in $(seq 1 30); do
  aws sqs send-message \
    --queue-url "${SQS_URL}" \
    --message-body "eks-load-${i}" > /dev/null
done
echo "30 メッセージ送信完了"

# KEDA が ScaledObject を評価して HPA を更新する（15 秒以内）
kubectl get scaledobject -n deepdive
kubectl get hpa -n deepdive

# Worker Pod の変化を監視
kubectl get pods -n deepdive -l app=job-worker --watch
```

### Step 3-10: ゼロスケールを確認する【ECS との決定的な違い】

```bash
# キューが空になった後、Worker が 0 になることを確認
watch kubectl get pods -n deepdive

# Karpenter がノードも削除することを確認（consolidateAfter=30s）
watch kubectl get nodes -l role=workload
```

> **ECS との違い**: ECS の Worker は `min_capacity=1` のため 0 にはならず、Fargate の課金が継続する。  
> EKS + KEDA では Pod=0 → Karpenter がノード削除 → EC2 コスト¥0 になる。

**Phase 3 完了チェック:**
- [ ] EKS クラスターが起動し system ノードが 2 台見える
- [ ] Karpenter が workload ノードをプロビジョニングした
- [ ] EKS ALB から `/health` が返る
- [ ] KEDA がメッセージ数に応じて Worker レプリカを増やした
- [ ] キュー空の後、Worker が 0 スケールになった
- [ ] Karpenter がノードを削除した

---

## Phase 4: 可観測性 + ロードテスト

**目標**: ECS vs EKS の差を実測データで証明できるようにする。

### Step 4-1: EKS Container Insights のセットアップ

```bash
cd terraform/eks
terraform apply \
  -target=aws_iam_role.cloudwatch_agent \
  -target=aws_iam_role_policy_attachment.cloudwatch_agent \
  -target=aws_eks_pod_identity_association.cloudwatch_agent \
  -target=aws_eks_addon.cloudwatch_observability \
  --auto-approve

# CloudWatch Agent が各ノードで起動していることを確認
kubectl get pods -n amazon-cloudwatch
```

### Step 4-2: CloudWatch ダッシュボードを確認する

Foundation の Terraform にダッシュボードが定義済みなので、ブラウザで開く:

```bash
cd ../foundation
terraform output dashboard_url
# → https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?...
```

ダッシュボードには以下のウィジェットがある:
- **SQS キュー深度**: ロードテスト中にキューが積まれる様子
- **Worker 数比較**: ECS タスク数 vs EKS Pod 数の並列表示
- **ECS/EKS CPU 使用率**: スケーリング前後の変化
- **ALB レスポンスタイム**: p50/p95/p99 の ECS vs EKS 比較

### Step 4-3: ロードテストを実行する

事前に ALB URL を確認する:

```bash
ECS_URL="http://$(cd terraform/ecs && terraform output -raw alb_dns_name)"
EKS_URL="http://$(kubectl get ingress api-server -n deepdive \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"

echo "ECS: ${ECS_URL}"
echo "EKS: ${EKS_URL}"

# 両方疎通確認
curl -s "${ECS_URL}/health"
curl -s "${EKS_URL}/health"
```

ロードテストを実行する（aiohttp が必要）:

```bash
pip3 install aiohttp --quiet

# 200 ジョブを並列 20 で ECS→EKS の順に実行
python3 scripts/load_test.py \
  --target both \
  --ecs-url "${ECS_URL}" \
  --eks-url "${EKS_URL}" \
  --jobs 200 \
  --concurrency 20
```

**出力例:**

```
══════════════════════════════════════════════════════════════
  ECS vs EKS 定量比較
══════════════════════════════════════════════════════════════
  指標                 ECS (Fargate)         EKS (Karpenter)
  ────────────────────────────────────────────────────────────
  RPS                  ___ req/s             ___ req/s
  p50 レイテンシ        ___ ms                ___ ms
  p95 レイテンシ        ___ ms                ___ ms
  p99 レイテンシ        ___ ms                ___ ms
  エラー数              ___ 件                ___ 件
```

結果は `load_test_results.json` に保存される。

### Step 4-4: スケーリング速度を計測する

ロードテスト中に別ターミナルで実行して、スケールアウト開始時刻を記録する:

```bash
# ECS Worker タスク数を 5 秒ごとに監視
watch -n 5 "aws ecs describe-services \
  --cluster deepdive-ecs \
  --services deepdive-worker \
  --query 'services[0].{desired:desiredCount,running:runningCount}' \
  --output table"

# EKS Worker Pod 数を 5 秒ごとに監視（別ターミナル）
watch -n 5 "kubectl get pods -n deepdive -l app=job-worker --no-headers | wc -l"
```

**計測値記録シート:**

```
ロードテスト (200 jobs / 20 concurrency)
  ECS: p50=___ms  p95=___ms  p99=___ms  RPS=___
  EKS: p50=___ms  p95=___ms  p99=___ms  RPS=___

スケールアウト開始まで
  ECS: ___秒  (CloudWatch Alarm 評価 60s が律速)
  EKS: ___秒  (KEDA ポーリング 15s + Karpenter 起動)

Karpenter ノード起動時間: ___秒
ECS タスク PENDING → RUNNING: ___秒
```

**Phase 4 完了チェック:**
- [ ] ロードテストが両方エラーなく完了
- [ ] 計測値記録シートの数値を埋めた
- [ ] CloudWatch ダッシュボードで Worker 数の増減が可視化できた

---

## Phase 5: ADR + クリーンアップ

**目標**: ハンズオンの体験を言語化してポートフォリオ資産にする。そしてリソースを完全削除してコスト発生を止める。

### Step 5-1: ADR-001 の Decision セクションを自分の言葉で書く

```bash
# テンプレートが既にある
cat docs/adr-001-ecs-vs-eks.md
```

`## Decision` セクションを**自分の計測値と感想**で埋める。以下は問いかけ:

- 計測値を見て、予想と違った点は何か？
- KEDA + Karpenter の組み合わせを実際に動かしてみてどう感じたか？
- 次のプロジェクトで ECS/EKS どちらを選ぶか、その理由は？

### Step 5-2: 口頭説明 15 分チェック

ノートなし・15 分で以下を説明できれば合格:

```
□ アーキテクチャ全体を口頭で描ける（5 分）
  - ECS 側: ALB → API (Service Connect) → SQS → Worker (SIGTERM)
  - EKS 側: ALB (LBC) → API (PDB, topologySpread) → SQS → Worker (KEDA 0→N)
  - 共通: ECR, SSM, CloudWatch, VPC Endpoints

□ ECS 設計根拠を語れる（3 分）
  - なぜ base=1, weight=4 か（Fargate 最低 1 台保証 + Spot 最大活用）
  - なぜ spread → binpack の順か（AZ 耐障害性優先、その後コスト最適化）
  - Service Connect vs Cloud Map DNS の違い

□ EKS 設計根拠を語れる（3 分）
  - なぜ Karpenter か（CA より速いプロビジョニング、consolidation）
  - なぜ Pod Identity か（k8s manifest に IAM 情報を持ち込まない）
  - KEDA minReplicaCount=0 のビジネス価値

□ 実測値を根拠に選定基準を語れる（3 分）
  - p95 レイテンシの差: ECS=___ms vs EKS=___ms
  - スケールアウト速度の差とその理由
  - 次のプロジェクトでどちらを選ぶか
```

### Step 5-3: リソースのクリーンアップ

> ⚠️ **順序厳守**: k8s → Helm → EKS → ECS → Foundation の順で削除する。逆順にすると依存関係でエラーになる。

**1. Kubernetes リソースを削除する:**

```bash
kubectl delete -f k8s/manifests/ --ignore-not-found
kubectl delete namespace deepdive --ignore-not-found
```

**2. Helm リリースを削除する:**

```bash
helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
helm uninstall keda -n keda 2>/dev/null || true
helm uninstall karpenter -n karpenter 2>/dev/null || true
```

**3. EKS Terraform を削除する:**

```bash
cd terraform/eks
terraform destroy --auto-approve
cd ../..

# 確認（クラスターが消えていること）
aws eks list-clusters --query 'clusters'
```

**4. ECS Terraform を削除する:**

```bash
cd terraform/ecs
terraform destroy --auto-approve
cd ../..
```

**5. Foundation Terraform を削除する:**

ECR にイメージが残っていると Terraform が失敗するため、先に削除する:

```bash
for repo in api-server job-worker; do
  IMAGE_IDS=$(aws ecr list-images \
    --repository-name "${repo}" \
    --query 'imageIds' --output json)
  if [ "${IMAGE_IDS}" != "[]" ]; then
    aws ecr batch-delete-image \
      --repository-name "${repo}" \
      --image-ids "${IMAGE_IDS}"
    echo "${repo}: イメージ削除完了"
  fi
done
```

```bash
cd terraform/foundation
terraform destroy --auto-approve
cd ../..
```

**6. 残留リソースがないことを確認する:**

```bash
echo "=== 残留リソース確認 ==="
aws ecs list-clusters --query 'clusterArns'
aws eks list-clusters --query 'clusters'
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=ecs-eks-deepdive" \
  --query 'Vpcs[].VpcId'
aws sqs list-queues --queue-name-prefix deepdive
echo "上記がすべて空であればクリーンアップ完了"
```

---

## トラブルシューティング

### ECS タスクが PENDING のまま起動しない

```bash
# タスク起動失敗の理由を確認
aws ecs describe-tasks \
  --cluster deepdive-ecs \
  --tasks $(aws ecs list-tasks --cluster deepdive-ecs --query 'taskArns[0]' --output text) \
  --query 'tasks[0].stoppedReason'

# よくある原因:
# 1. ECR イメージが存在しない → Phase 1 の docker push を確認
# 2. VPC Endpoint 経由で ECR にアクセスできない → Endpoint の SG を確認
# 3. SSM パラメータが取得できない → IAM の ecs-exec-role を確認
```

### kubectl コマンドが EKS に接続できない

```bash
# kubeconfig を再設定
aws eks update-kubeconfig --name deepdive-eks --region ap-northeast-1

# 現在のコンテキストを確認
kubectl config current-context
```

### Karpenter がノードを起動しない

```bash
# Karpenter のログを確認
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=50

# EC2NodeClass のステータスを確認
kubectl describe ec2nodeclass workload

# よくある原因:
# 1. IAM Role の PassRole 権限が不足
# 2. サブネットタグ (kubernetes.io/role/internal-elb: "1") がない
# 3. セキュリティグループタグ (aws:eks:cluster-name: deepdive-eks) がない
```

### EKS ALB が作成されない（ADDRESS が空のまま）

```bash
# LBC のログを確認
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50

# Ingress の Events を確認
kubectl describe ingress api-server -n deepdive

# よくある原因:
# 1. Pod Identity Association が正しく設定されていない
# 2. Public Subnet に kubernetes.io/role/elb: "1" タグがない
# 3. LBC の ServiceAccount 名が Pod Identity Association と不一致
```

### KEDA が SQS にアクセスできない

```bash
# TriggerAuthentication のステータスを確認
kubectl describe triggerauthentication keda-pod-identity -n deepdive

# Pod Identity Association を確認
aws eks list-pod-identity-associations \
  --cluster-name deepdive-eks \
  --query 'associations[*].{ns:namespace,sa:serviceAccount,role:roleArn}'
```

---

## ディレクトリ構成

```
ecs-eks-deepdive-lab/
├── CLAUDE.md                   ← AI へのプロジェクト制約・指示
├── ARCHITECTURE.md             ← アーキテクチャ詳細解説
├── README.md                   ← このファイル
├── phase1.md 〜 phase5.md      ← AI 向けフェーズ別実装指示書
│
├── app/
│   ├── api/
│   │   ├── main.py             ← FastAPI (POST /jobs, GET /health)
│   │   ├── requirements.txt    ← fastapi, boto3, structlog
│   │   └── Dockerfile          ← python:3.12-slim, arm64, non-root
│   └── worker/
│       ├── main.py             ← SQS ポーリング + SIGTERM ハンドラー
│       ├── requirements.txt    ← boto3, structlog
│       └── Dockerfile          ← python:3.12-slim, arm64, non-root
│
├── terraform/
│   ├── foundation/             ← Phase 1: VPC, ECR, SQS, IAM, Endpoints
│   ├── ecs/                    ← Phase 2: ECS Cluster, Services, Scaling
│   └── eks/                    ← Phase 3: EKS Cluster, Karpenter, Addons
│
├── k8s/
│   └── manifests/
│       ├── namespace.yaml
│       ├── serviceaccounts.yaml
│       ├── karpenter-nodepool.yaml
│       ├── api.yaml            ← Deployment + PDB + Service + Ingress
│       └── worker.yaml         ← Deployment + KEDA ScaledObject
│
├── scripts/
│   └── load_test.py            ← ECS vs EKS 非同期ロードテスト
│
└── docs/
    ├── adr-001-ecs-vs-eks.md   ← Architecture Decision Record
    ├── runbook.md              ← ECS/EKS 運用手順
    ├── interview-star.md       ← 面接 STAR Q&A
    └── zenn-outline.md         ← 記事アウトライン
```

---

## 主要設定値リファレンス

| 項目 | 値 |
|------|----|
| リージョン | `ap-northeast-1` |
| VPC CIDR | `10.0.0.0/16` |
| EKS バージョン | `1.30` |
| コンピューティング | `arm64` (Graviton2) 統一 |
| アプリポート | `8080` |
| SQS visibility timeout | `300` 秒 |
| ECS Worker stopTimeout | `30` 秒 |
| KEDA pollingInterval | `15` 秒 |
| Karpenter consolidateAfter | `30` 秒 |
| Karpenter expireAfter | `168h` (7 日) |
