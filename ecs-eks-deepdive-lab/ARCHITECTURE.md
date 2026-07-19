# ECS/EKS Deep Dive Lab — アーキテクチャ完全解説

## 目次

1. [ラボの目的](#1-ラボの目的)
2. [全体アーキテクチャ](#2-全体アーキテクチャ)
3. [ワークロード：アプリケーション仕様](#3-ワークロードアプリケーション仕様)
4. [共通インフラ（Foundation）](#4-共通インフラfoundation)
5. [ECS 側アーキテクチャ](#5-ecs-側アーキテクチャ)
6. [EKS 側アーキテクチャ](#6-eks-側アーキテクチャ)
7. [IAM 設計](#7-iam-設計)
8. [可観測性](#8-可観測性)
9. [Terraform 構成](#9-terraform-構成)
10. [ECS vs EKS 比較まとめ](#10-ecs-vs-eks-比較まとめ)

---

## 1. ラボの目的

**同一ワークロード**（FastAPI ジョブ API + SQS Worker）を ECS と EKS の両方にデプロイし、スケーリング挙動・運用手順・コストを実測データで比較する。

> インタビューで「ECS と EKS、どちらを選ぶか？なぜか？」を実体験 × 定量データで即答できるレベルを目標とする。

---

## 2. 全体アーキテクチャ

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Internet                                       │
└────────────────────────┬───────────────────────┬────────────────────────┘
                         │                       │
              ┌──────────▼──────────┐ ┌──────────▼──────────┐
              │  ECS ALB            │ │  EKS ALB (AWS LBC)  │
              │  deepdive-alb       │ │  (Ingress 経由で作成) │
              │  Public Subnets     │ │  Public Subnets      │
              └──────────┬──────────┘ └──────────┬──────────┘
                         │                       │
          ┌──────────────┼───────────────────────┼──────────────────┐
          │              │    VPC: 10.0.0.0/16   │                  │
          │  ┌───────────▼────────────┐ ┌────────▼────────────────┐ │
          │  │    ECS Cluster         │ │    EKS Cluster          │ │
          │  │    deepdive-ecs        │ │    deepdive-eks (1.30)  │ │
          │  │                        │ │                         │ │
          │  │  ┌─────────────────┐   │ │  ┌──────────────────┐  │ │
          │  │  │ API Service      │   │ │  │ API Deployment   │  │ │
          │  │  │ Fargate(base=1) │   │ │  │ replicas: 2      │  │ │
          │  │  │ +Spot(weight=4) │   │ │  │ Karpenter Spot   │  │ │
          │  │  │ Service Connect  │   │ │  │ arm64 c/m/r6g    │  │ │
          │  │  │ ECS Exec 有効   │   │ │  │ topologySpread   │  │ │
          │  │  └─────────────────┘   │ │  │ PDB min=1        │  │ │
          │  │                        │ │  └──────────────────┘  │ │
          │  │  ┌─────────────────┐   │ │                         │ │
          │  │  │ Worker Service   │   │ │  ┌──────────────────┐  │ │
          │  │  │ Fargate Spot 100│   │ │  │ Worker Deployment │  │ │
          │  │  │ StepScaling     │   │ │  │ KEDA ScaledObject │  │ │
          │  │  │ min=1, max=10   │   │ │  │ min=0, max=10    │  │ │
          │  │  │ SIGTERM 30s     │   │ │  │ terminationGrace │  │ │
          │  │  └─────────────────┘   │ │  │ Period=60s       │  │ │
          │  └────────────────────────┘ │  └──────────────────┘  │ │
          │                             └─────────────────────────┘ │
          │                                                          │
          │         ┌────────────────────────────────────┐           │
          │         │          共通インフラ                │           │
          │         │                                    │           │
          │         │  SQS: deepdive-job-queue           │           │
          │         │  ├─ visibility timeout: 300s       │           │
          │         │  └─ DLQ: deepdive-job-dlq (14日)  │           │
          │         │                                    │           │
          │         │  ECR: api-server, job-worker       │           │
          │         │  SSM: /deepdive/sqs-queue-url      │           │
          │         └────────────────────────────────────┘           │
          │                                                          │
          │  VPC Endpoints (Private Subnet → AWSサービス)            │
          │  ECR API/DKR, S3(GW), CloudWatch Logs, SSM,             │
          │  SSMMESSAGES, EC2MESSAGES, STS, SQS, EC2                │
          └──────────────────────────────────────────────────────────┘
```

### ネットワーク構成

```
VPC: 10.0.0.0/16 (ap-northeast-1)

Public Subnets (ALB 配置)          Private Subnets (Compute 配置)
┌──────────────────────────┐       ┌──────────────────────────────┐
│ 1a: 10.0.0.0/24          │       │ 1a: 10.0.128.0/24            │
│ 1c: 10.0.1.0/24          │       │ 1c: 10.0.129.0/24            │
│                          │       │                              │
│ タグ: elb=1              │       │ タグ: internal-elb=1         │
│       (LBC Public ALB用) │       │       (LBC Internal ALB用)   │
└──────────────────────────┘       └──────────────────────────────┘
         │ IGW                              │ NAT GW (1a のみ)
         ▼                                 ▼
   Internet                         Internet (EKS Addon用)
```

**NAT Gateway を 1 台に絞る理由：** Karpenter・KEDA などの EKS アドオンが ECR Public からイメージを取得する際に必要。本番では ECR pull-through cache + VPC Endpoint に置き換えてコスト削減する（ADR-001 参照）。

---

## 3. ワークロード：アプリケーション仕様

### アプリ全体のフロー

```
クライアント
    │
    │ POST /jobs {"payload": "..."}
    ▼
[API Server: FastAPI]
    │
    │ sqs.send_message()
    ▼
[SQS: deepdive-job-queue]
    │
    │ sqs.receive_message() ロングポーリング(20s)
    ▼
[Job Worker]
    │
    │ 処理成功 → sqs.delete_message()
    │ 処理失敗 → visibility timeout 後に再試行 (最大3回)
    ▼
[DLQ: deepdive-job-dlq]  ← 3回失敗時に移動、14日間保持
```

### API Server (`app/api/`)

| 項目 | 仕様 |
|------|------|
| フレームワーク | FastAPI |
| ランタイム | Python 3.12-slim |
| ロギング | structlog (JSON 形式) |
| エンドポイント | `POST /jobs` — ジョブをSQSへエンキュー |
| ヘルスチェック | `GET /health` — 常時 200 返却 |
| ポート | 8080 |
| セキュリティ | root以外(UID 1000)で実行 |

**HEALTHCHECK の二重定義：** Dockerfile レベルの `HEALTHCHECK` は ECS ヘルスチェックで使用。ECS タスク定義の `healthCheck` 設定は ECS コントロールプレーンが直接評価する。両方定義することでコンテナレベル・サービスレベルの二段階チェックが機能する。

### Job Worker (`app/worker/`)

| 項目 | 仕様 |
|------|------|
| ランタイム | Python 3.12-slim |
| ロギング | structlog (JSON 形式) |
| ポーリング方式 | SQS ロングポーリング (WaitTimeSeconds=20) |
| バッチサイズ | MaxNumberOfMessages=10 |
| SIGTERM 処理 | signal.signal() で graceful shutdown 実装 |
| 失敗処理 | delete_message を呼ばず DLQ に流す |

```python
# SIGTERM ハンドラーの動作
running = True          # 初期状態

SIGTERM 受信
    ↓
running = False         # フラグ反転

現在のメッセージ処理完了  ← ここまでは必ず完了させる
    ↓
while ループ終了 → プロセス終了
```

**ECS の stopTimeout=30s と連動：** ECS が SIGTERM → SIGKILL するまでの 30 秒以内に Worker が処理中メッセージを完了させる設計。

---

## 4. 共通インフラ（Foundation）

`terraform/foundation/` が管理するリソース。ECS/EKS の両方から参照される。

### SQS キュー設計

```
┌──────────────────────────────────────────────────────┐
│ deepdive-job-queue                                   │
│                                                      │
│  visibility_timeout: 300s  ← Workerの最大処理時間    │
│  receive_wait_time:  20s   ← ロングポーリング         │
│  message_retention: 1日                              │
│  SSE: SQS managed key                               │
│                                                      │
│  redrive_policy:                                     │
│    maxReceiveCount: 3      ← 3回失敗でDLQへ          │
│    deadLetterTargetArn: deepdive-job-dlq             │
└──────────────────────────────────────────────────────┘
                      │ 3回失敗
                      ▼
┌──────────────────────────────────────────────────────┐
│ deepdive-job-dlq                                     │
│  message_retention: 14日   ← 障害調査のための期間     │
│  SSE: SQS managed key                               │
└──────────────────────────────────────────────────────┘
```

**visibility timeout を 300 秒にする理由：** Worker が処理中に別の Worker が同じメッセージを受信してしまう「二重処理」を防ぐ。`time.sleep(2)` の処理シミュレーションに余裕を持たせた安全マージン。

### ECR リポジトリ

```
ECR リポジトリ (ap-northeast-1)
├── api-server        ← FastAPI コンテナイメージ
│   ├── scan_on_push: true  (プッシュ時に自動脆弱性スキャン)
│   └── lifecycle: untagged イメージを7日後に自動削除
└── job-worker        ← SQS Worker コンテナイメージ
    ├── scan_on_push: true
    └── lifecycle: untagged イメージを7日後に自動削除
```

### VPC Endpoint 一覧

```
Interface Endpoints (ENI 経由、有料):
  ecr.api      → ECR イメージのメタデータ・認証トークン取得
  ecr.dkr      → ECR イメージのレイヤーデータ転送
  logs         → CloudWatch Logs へのコンテナログ送信
  ssm          → SSM Parameter Store のシークレット取得
  ssmmessages  → ECS Exec / SSM Session Manager の通信チャネル
  ec2messages  → SSM Agent ↔ Systems Manager 間の制御メッセージ
  sts          → Pod Identity / ECS タスクロールの認証トークン
  sqs          → SQS へのメッセージ送受信
  ec2          → Karpenter の EC2 インスタンス作成・削除

Gateway Endpoint (ルートテーブル経由、無料):
  s3           → ECR のレイヤーストレージ・EKS Bootstrap スクリプト
```

---

## 5. ECS 側アーキテクチャ

`terraform/ecs/` が管理。

### クラスターと Capacity Provider

```
ECS Cluster: deepdive-ecs
  Container Insights: enabled  ← CloudWatch に CPU/Memory/ネットワーク送信

Capacity Provider Strategy (default + API Service 個別設定):
  FARGATE      base=1, weight=1
  FARGATE_SPOT base=0, weight=4

タスク数別の Fargate / Spot 分配:
  1 タスク  → Fargate:1  Spot:0  (base=1 を優先消化)
  2 タスク  → Fargate:1  Spot:1
  5 タスク  → Fargate:1  Spot:4
  10 タスク → Fargate:2  Spot:8

Worker Service は Spot 100%:
  処理失敗は SQS visibility timeout が自動リトライ
  → Spot 中断によるメッセージロストを SQS が吸収する設計
```

### タスク定義 (Task Definitions)

```
API Task Definition:
  family: deepdive-api
  cpu: 512  memory: 1024
  runtime_platform: ARM64 / LINUX  ← Graviton2 統一方針

  container:
    image: <ECR_API_URL>:latest
    portMappings:
      name: "api"         ← Service Connect が参照する名前
      port: 8080
      appProtocol: http   ← Service Connect が HTTP/1.1 でルーティング
    secrets:
      SQS_QUEUE_URL: from SSM /deepdive/sqs-queue-url
    environment:
      AWS_REGION: ap-northeast-1
    logConfiguration:
      driver: awslogs  → /ecs/deepdive/api
    healthCheck:
      CMD: curl localhost:8080/health
      interval: 30s / timeout: 5s / retries: 3 / startPeriod: 10s
    linuxParameters:
      initProcessEnabled: true  ← PID 1 を init にしてゾンビプロセス防止

Worker Task Definition:
  family: deepdive-worker
  cpu: 256  memory: 512
  runtime_platform: ARM64 / LINUX

  container:
    stopTimeout: 30  ← SIGTERM から SIGKILL まで 30 秒待機
    secrets:
      SQS_QUEUE_URL: from SSM /deepdive/sqs-queue-url
    logConfiguration: → /ecs/deepdive/worker
```

### Service Connect (API サービス間通信)

```
Service Connect の仕組み:

┌──────────────────────────────────────────────────────────────┐
│  ECS Service: deepdive-api                                   │
│                                                              │
│  ┌─────────────────────┐    ┌──────────────────────────┐    │
│  │  API Container       │    │  Envoy Sidecar           │    │
│  │  (port 8080)         │◄───│  (Service Connect Proxy) │    │
│  └─────────────────────┘    └──────────────────────────┘    │
│                                                              │
│  Cloud Map HTTP Namespace: deepdive.local                    │
│  Discovery Name: api                                         │
│  Client Alias: http://api:8080                               │
└──────────────────────────────────────────────────────────────┘

Cloud Map DNS namespace との違い:
  DNS方式: DNS クエリで IP を解決 → 直接通信（シンプルだが機能少）
  Service Connect: Envoy がプロキシ → Retry/Circuit Breaker/メトリクスが無料
```

### タスク配置戦略

```
ordered_placement_strategy:

1. spread(attribute:ecs.availability-zone)
   ┌───────────────────────────────────────┐
   │  AZ 1a          AZ 1c                 │
   │  [Task] [Task]  [Task] [Task]          │
   │  AZ 障害時の影響を最小化              │
   └───────────────────────────────────────┘

2. binpack(cpu)
   AZ 内では CPU を詰め込み、タスク密度を最大化
   (Fargate では実際のコスト差は小さいが EC2 起動型で意味が大きい)
```

### ALB とセキュリティグループ

```
Internet
  │ HTTP:80
  ▼
┌──────────────────────────────────────────┐
│ ALB SG (deepdive-alb-sg)                 │
│  Ingress: 0.0.0.0/0 → :80               │
│  Egress:  → ECS Tasks SG :8080 のみ      │
└──────────────────────┬───────────────────┘
                       │ HTTP:8080
                       ▼
┌──────────────────────────────────────────┐
│ ECS Tasks SG (deepdive-ecs-tasks-sg)     │
│  Ingress: ALB SG → :8080 のみ            │
│  Egress:  → 0.0.0.0/0 :443              │
│           (VPC Endpoint 経由)            │
└──────────────────────────────────────────┘
```

### Worker スケーリング (Step Scaling)

```
SQS: ApproximateNumberOfMessagesVisible

メトリクス
    │
    │ 60秒ごとに評価
    ▼
CloudWatch Alarm: deepdive-sqs-scale-out
  threshold >= 10  → StepScaling Policy 発火

Step Scaling:
  深度 10〜49  → +2 タスク (cooldown: 60s)
  深度 50+     → +5 タスク

CloudWatch Alarm: deepdive-sqs-scale-in
  threshold < 5  が 2分間(evaluation_periods=2) 継続
  → -1 タスク (cooldown: 120s)
                            ↑
                       スケールインは
                       スケールアウトの
                       2倍の cooldown で
                       「揺れ」防止

Min: 1 タスク  Max: 10 タスク
```

### ECS Exec

```
コンテナへのシェルアクセス手順:

aws ecs execute-command \
  --cluster deepdive-ecs \
  --task <TASK_ARN> \
  --container api \
  --interactive \
  --command /bin/sh

必要な IAM 権限 (ecs_task_role に付与):
  ssmmessages:CreateControlChannel
  ssmmessages:CreateDataChannel
  ssmmessages:OpenControlChannel
  ssmmessages:OpenDataChannel
  ※ Resource: "*" が必須 (AWS の制約)
```

---

## 6. EKS 側アーキテクチャ

`terraform/eks/` と `k8s/manifests/` が管理。

### クラスター構成

```
EKS Cluster: deepdive-eks (Kubernetes 1.30)
  authentication_mode: API  ← aws-auth ConfigMap 廃止、EKS Access Entries で管理
  endpoint_private_access: true  ← Karpenter ノードが VPC 内から API サーバーへ
  endpoint_public_access:  true  ← ローカルから kubectl 実行用
  enabled_cluster_log_types: [api, audit, authenticator]

┌──────────────────────────────────────────────────────────┐
│                 EKS ノード構成                            │
│                                                          │
│  System Node Group (Managed, AL2_ARM_64, t4g.medium)     │
│  ┌───────────────────────────────────────────────────┐   │
│  │  Taint: CriticalAddonsOnly=true:NoSchedule        │   │
│  │  Label: role=system                               │   │
│  │  用途: CoreDNS / Karpenter Controller / KEDA      │   │
│  │  desired: 2 / min: 2 / max: 4                     │   │
│  └───────────────────────────────────────────────────┘   │
│                                                          │
│  Workload Nodes (Karpenter 管理, Spot arm64)             │
│  ┌───────────────────────────────────────────────────┐   │
│  │  Label: role=workload                             │   │
│  │  用途: API Server Pod / Job Worker Pod            │   │
│  │  インスタンス: c6g/m6g/r6g .medium/.large         │   │
│  │  AZ: 1a, 1c                                       │   │
│  └───────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### マネージドアドオン

```
aws_eks_addon で一括管理 (for_each):

vpc-cni
  └─ ENABLE_PREFIX_DELEGATION=true
     WARM_PREFIX_TARGET=1
     → /28 プレフィックス割り当てで 1 ノードあたりの Pod 数上限を大幅増加

coredns
  └─ サービス間の DNS 解決

kube-proxy
  └─ Service の ClusterIP ルーティング

eks-pod-identity-agent
  └─ Pod Identity の認証仲介エージェント (OIDC 不要の新方式)

amazon-cloudwatch-observability  (Phase 4 で追加)
  └─ Container Insights + CloudWatch Logs を一括セットアップ
```

### Karpenter (ノードオートスケーリング)

```
Karpenter の動作フロー:

Pod がスケジュール不可 (Pending)
    │
    │ Karpenter がウォッチ
    ▼
Pod の requirements を確認:
  - arch: arm64
  - capacity-type: spot
  - instance-type: c6g/m6g/r6g .medium/.large
  - zone: ap-northeast-1a or 1c
    │
    ▼
最適インスタンスタイプを選択
(Spot 可用性 + 価格 + Pod リソース request から計算)
    │
    ▼
EC2 Fleet API でノード起動 → ノードが Ready に
    │
    ▼
Pending Pod がスケジュール

Cluster Autoscaler との違い:
  CA: Node Group 単位で ASG をスケール
      → スケールアップに 2〜3分かかることがある
  Karpenter: Pod の要件から直接 EC2 を起動
      → スケールアップが約 60 秒で完了
```

**EC2NodeClass 設定:**

```yaml
amiFamily: AL2          # Amazon Linux 2 (arm64 対応)
role: deepdive-eks-node-role

subnetSelectorTerms:
  - tags:
      kubernetes.io/role/internal-elb: "1"   # Private Subnet を自動選択

securityGroupSelectorTerms:
  - tags:
      aws:eks:cluster-name: deepdive-eks      # EKS が自動付与するタグ

blockDeviceMappings:
  - deviceName: /dev/xvda
    volumeSize: 20Gi / volumeType: gp3 / encrypted: true
```

**NodePool 設定:**

```yaml
expireAfter: 168h   # 7日でノードをローテーション (セキュリティパッチ適用)

disruption:
  consolidationPolicy: WhenUnderutilized
  consolidateAfter: 30s  # 30秒後に未使用ノードを統合
  budgets:
    - nodes: "20%"  # 同時に disruption できるノードは最大20%
                    # PodDisruptionBudget と連携して動作
```

### Karpenter の Spot 割り込み対応

```
EC2 Spot 割り込み通知 (2分前に通知)
    │
    │ aws.ec2 イベント
    ▼
EventBridge Rule: deepdive-karpenter-spot-interruption
    │
    ▼
SQS: deepdive-karpenter-interrupt (retention: 300s)
    │
    │ Karpenter がポーリング
    ▼
該当ノードの Pod を事前退避 (cordon + drain)
    │
    ▼
Karpenter が新しいノードをプロビジョニング
    │
    ▼
Pod が新ノードに再スケジュール
```

### KEDA (イベント駆動オートスケーリング)

```
SQS キュー深度
    │
    │ 15秒ごとにポーリング (pollingInterval: 15)
    ▼
KEDA ScaledObject → HPA を動的生成
    │
    ├─ queueLength: 5    (1 Pod あたりのメッセージ数)
    │   例: 25 messages → 5 Pods
    │
    ├─ minReplicaCount: 0  ← キュー空ならゼロスケール
    │   → Karpenter がノードも削除 → EC2 コストゼロ
    │
    └─ maxReplicaCount: 10
       activationQueueLength: 1  (0→1 への起動閾値)

ECS StepScaling との比較:
  ECS: CloudWatch Alarm 60s → AppAutoScaling → タスク起動
  EKS: KEDA 15s ポーリング → HPA → Karpenter → ノード+Pod
       EKS のほうが約4倍速く反応できる
```

### API Deployment 配置設計

```
topologySpreadConstraints:
  maxSkew: 1
  topologyKey: topology.kubernetes.io/zone
  whenUnsatisfiable: DoNotSchedule  ← AZ 偏りを許容しない

例: 2 Pods の場合
  ┌─────────────────────────────┐
  │  AZ 1a          AZ 1c       │
  │  [api-pod-1]   [api-pod-2]  │
  │                             │
  │  skew = |1-1| = 0  ✓       │
  └─────────────────────────────┘

PodDisruptionBudget (api-server-pdb):
  minAvailable: 1
  → Karpenter の node consolidation 中も最低 1 Pod を維持
  → karpenter disruption budget(20%) と連携して安全に動作
```

### Pod Identity (IAM 認証)

```
Pod Identity (2023 年〜の新方式)  vs  OIDC IRSA (旧方式)

OIDC IRSA:
  EKS クラスター
    └─ OIDC Provider 作成が必要
  ServiceAccount
    └─ annotations:
         eks.amazonaws.com/role-arn: <ARN>  ← 手動で書く

Pod Identity:
  EKS クラスター
    └─ eks-pod-identity-agent アドオンのみ追加
  aws_eks_pod_identity_association リソースで紐付け
  ServiceAccount への annotations 不要

このラボの Pod Identity 一覧:
  Namespace       ServiceAccount          IAM Role
  ─────────────────────────────────────────────────────────
  kube-system     aws-load-balancer-ctrl  deepdive-lbc-role
  keda            keda-operator           deepdive-keda-role
  deepdive        api-server              deepdive-api-role
  deepdive        job-worker              deepdive-worker-role
  karpenter       karpenter               deepdive-karpenter-ctrl
  amazon-cloudwatch cloudwatch-agent      deepdive-eks-cw-agent
```

### AWS Load Balancer Controller (LBC)

```
kubectl apply -f k8s/manifests/api.yaml
    │
    │ Ingress リソース作成
    ▼
LBC が Ingress を検知
    │
    ▼
AWS ALB を自動プロビジョニング:
  scheme: internet-facing
  target-type: ip  (Pod の IP を直接ターゲット)
  subnets: Public Subnets (sed で <PUBLIC_SUBNET_IDS> を置換)
  healthcheck-path: /health

annotations の役割:
  alb.ingress.kubernetes.io/scheme: internet-facing
  alb.ingress.kubernetes.io/target-type: ip
  alb.ingress.kubernetes.io/subnets: <Public Subnet IDs>
  alb.ingress.kubernetes.io/healthcheck-path: /health

spec.ingressClassName: alb  ← K8s 1.19+ 正式方式
```

---

## 7. IAM 設計

### IAM ロール一覧

```
Foundation が管理 (foundation/iam.tf):
┌─────────────────────────────────────────────────────────────────┐
│ deepdive-ecs-exec-role                                          │
│  AmazonECSTaskExecutionRolePolicy (managed)                     │
│  + SSM GetParameter: /deepdive/* のみ (最小権限)                │
│  用途: ECS エージェントがタスクを起動 (ECRプル・CWLogs・SSM取得) │
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ deepdive-ecs-task-role                                          │
│  SQS: SendMessage/ReceiveMessage/DeleteMessage (job-queue ARN)  │
│  ssmmessages:* (ECS Exec 用, Resource: * が AWS の要件)         │
│  用途: タスク内のアプリコードが使用                              │
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ deepdive-eks-node-role                                          │
│  AmazonEKSWorkerNodePolicy (managed)                            │
│  AmazonEC2ContainerRegistryReadOnly (managed)                   │
│  AmazonEKS_CNI_Policy (managed)                                 │
│  用途: Karpenter が起動する EC2 ノードの Instance Profile        │
└─────────────────────────────────────────────────────────────────┘

EKS が管理 (eks/addon_roles.tf):
┌─────────────────────────────────────────────────────────────────┐
│ deepdive-lbc-role        (Pod Identity: kube-system/lbc)        │
│ deepdive-keda-role       (Pod Identity: keda/keda-operator)     │
│ deepdive-api-role        (Pod Identity: deepdive/api-server)    │
│ deepdive-worker-role     (Pod Identity: deepdive/job-worker)    │
│ deepdive-karpenter-ctrl  (Pod Identity: karpenter/karpenter)    │
│ deepdive-eks-cw-agent    (Pod Identity: amazon-cloudwatch/cwa)  │
└─────────────────────────────────────────────────────────────────┘
```

### 最小権限の設計思想

```
各ロールの権限スコープ:

API Server (ECS/EKS 共通):
  sqs:SendMessage → job-queue ARN のみ

Job Worker (ECS/EKS 共通):
  sqs:ReceiveMessage
  sqs:DeleteMessage       → job-queue ARN のみ
  sqs:GetQueueAttributes

KEDA:
  sqs:GetQueueAttributes  → job-queue ARN のみ
  sqs:GetQueueUrl

Karpenter:
  ec2:Describe* → * (API の設計上 Resource 指定不可)
  ec2:RunInstances/TerminateInstances → *
  iam:PassRole → eks-node-role ARN のみ
  eks:DescribeCluster → cluster ARN のみ
  sqs:* → interrupt queue ARN のみ

(注) * が必要なアクションは AWS サービス設計上の制約によるもの
     ワイルドカードを意図的に使っているわけではない
```

---

## 8. 可観測性

### CloudWatch ダッシュボード (deepdive-ecs-eks-comparison)

```
┌─────────────────────────────────┬──────────────────────────────────┐
│ SQS キュー深度                   │ Worker 数比較 (ECS vs EKS)       │
│ ・Visible Messages               │ ・ECS RunningTaskCount           │
│ ・Sent (送信数)                  │ ・EKS pod_number_of_running_     │
│ ・Processed (処理数)             │    containers                    │
├─────────────────────────────────┼──────────────────────────────────┤
│ ECS CPU 使用率                  │ EKS CPU 使用率                   │
│ (API + Worker)                  │ (API + Worker)                   │
├─────────────────────────────────┼──────────────────────────────────┤
│ ALB レスポンスタイム比較 (ECS vs EKS)                               │
│ ・p50 / p95 / p99                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

### ログの流れ

```
ECS:
  Container stdout/stderr
    → awslogs ドライバー
    → CloudWatch Logs
      /ecs/deepdive/api/{task-id}
      /ecs/deepdive/worker/{task-id}

EKS:
  Container stdout/stderr
    → Fluent Bit (amazon-cloudwatch-observability が管理)
    → CloudWatch Logs
      /aws/containerinsights/deepdive-eks/application
```

### ロードテスト (`scripts/load_test.py`)

```
python3 scripts/load_test.py \
  --target both \
  --ecs-url http://<ECS_ALB> \
  --eks-url http://<EKS_ALB> \
  --jobs 200 --concurrency 20

出力例:
  ══════════════════════════════════════════════════════════════
    ECS vs EKS 定量比較
  ══════════════════════════════════════════════════════════════
    指標                 ECS (Fargate)         EKS (Karpenter)
    ────────────────────────────────────────────────────────
    RPS                  48.2 req/s            51.7 req/s
    p50 レイテンシ        38.1 ms               35.2 ms
    p95 レイテンシ        124.5 ms              98.3 ms
    p99 レイテンシ        287.2 ms              189.6 ms
    エラー数              0 件                  0 件
```

---

## 9. Terraform 構成

### モジュール依存関係

```
terraform/foundation/  (Phase 1 で apply)
  ├── vpc.tf          → VPC, Subnets, NAT GW, Route Tables
  ├── endpoints.tf    → VPC Endpoints (Interface + Gateway)
  ├── sqs.tf          → job-queue + DLQ
  ├── ecr.tf          → api-server, job-worker リポジトリ
  ├── ssm.tf          → /deepdive/sqs-queue-url
  ├── iam.tf          → ECS Exec/Task Role, EKS Node Role
  ├── dashboard.tf    → CloudWatch 比較ダッシュボード
  └── outputs.tf      → region, project + 各ファイルの output
         │
         │ terraform_remote_state (ローカル tfstate 参照)
         ▼
terraform/ecs/         (Phase 2 で apply)
  ├── main.tf         → Provider + foundation outputs を locals に展開
  ├── cluster.tf      → ECS Cluster + Capacity Providers
  ├── task_definitions.tf → API/Worker タスク定義
  ├── services.tf     → ECS Services (Service Connect + タスク配置)
  ├── alb.tf          → ALB + Target Group + Listener
  ├── cloudmap.tf     → Cloud Map HTTP Namespace
  ├── security_groups.tf → ALB SG + ECS Tasks SG
  ├── scaling.tf      → Step Scaling + CloudWatch Alarms
  └── cloudwatch.tf   → Log Groups
         │
terraform/eks/         (Phase 3 で apply)
  ├── main.tf         → Provider + foundation outputs を locals に展開
  ├── cluster.tf      → EKS Cluster + System Node Group + Addons
  ├── addon_roles.tf  → Pod Identity Roles (LBC, KEDA, API, Worker, CW)
  ├── karpenter.tf    → Karpenter IAM Role + Interrupt Queue + EventBridge
  └── cloudwatch.tf   → CloudWatch Observability Addon

k8s/manifests/         (Phase 3 で kubectl apply)
  ├── namespace.yaml          → deepdive namespace
  ├── serviceaccounts.yaml    → api-server, job-worker SA
  ├── api.yaml                → Deployment + PDB + Service + Ingress
  ├── worker.yaml             → Deployment + KEDA ScaledObject + TriggerAuth
  └── karpenter-nodepool.yaml → EC2NodeClass + NodePool
```

### State 管理

```
ラボ環境: ローカル tfstate (シンプルさ優先)
  terraform/foundation/terraform.tfstate
  terraform/ecs/terraform.tfstate
  terraform/eks/terraform.tfstate

本番での推奨:
  S3 backend + DynamoDB ロック
  (CLAUDE.md のプロジェクト標準に記載)
```

### ECS/EKS から Foundation 参照の仕組み

```hcl
# terraform/ecs/main.tf
data "terraform_remote_state" "foundation" {
  backend = "local"
  config = {
    path = "../foundation/terraform.tfstate"
  }
}

locals {
  vpc_id             = data.terraform_remote_state.foundation.outputs.vpc_id
  private_subnet_ids = data.terraform_remote_state.foundation.outputs.private_subnet_ids
  ecr_api_url        = data.terraform_remote_state.foundation.outputs.ecr_api_url
  execution_role_arn = data.terraform_remote_state.foundation.outputs.ecs_exec_role_arn
  # ... etc
}
```

---

## 10. ECS vs EKS 比較まとめ

### スケーリング比較

| 観点 | ECS (Fargate) | EKS (Karpenter + KEDA) |
|------|--------------|------------------------|
| トリガー | CloudWatch Alarm (60秒評価) | KEDA ポーリング (15秒) |
| スケーリング単位 | ECS タスク | Pod + EC2 ノード |
| ゼロスケール | 不可 (min=1 が実質的な制約) | 可能 (minReplicaCount=0) |
| スケールアウト速度 | 60秒 〜 数分 | 15〜60秒 (ノード起動込み) |
| ノード管理 | 不要 (Fargate がサーバーレス) | Karpenter が自動管理 |

### 運用コスト比較

| 観点 | ECS (Fargate) | EKS (Karpenter) |
|------|--------------|-----------------|
| コントロールプレーン | 無料 | $0.10/時間 |
| コンピューティング | Fargate 料金 (固定) | Spot 60〜70% 割引 |
| ゼロスケール時 | タスク分の課金継続 | ノードが消えてゼロ |
| 運用負荷 | 低 (マネージド) | 中 (Karpenter 設定必要) |

### 選択基準

```
ECS を選ぶとき:
  ✓ チームの Kubernetes 経験が少ない
  ✓ 小〜中規模サービス (数十タスク以下)
  ✓ 運用コストを最小化したい
  ✓ AWS ネイティブ統合を最大限に使いたい (Service Connect 等)
  ✓ 迅速なデプロイ・シンプルな構成が優先

EKS を選ぶとき:
  ✓ Kubernetes エコシステム (Helm, ArgoCD 等) を使いたい
  ✓ 大規模サービス (数百 Pod 以上)
  ✓ ゼロスケールによるコスト最適化が重要
  ✓ マルチクラウド・クラウドポータビリティが必要
  ✓ 高度なスケーリング制御 (KEDA, カスタムメトリクス) が必要
```

### このラボで証明できる技術的判断

| 質問 | このラボで得られる答え |
|------|----------------------|
| base=1, weight=4 で 6 タスク時の内訳は？ | Fargate:2 / Spot:4 (base 消化後 1:4 で分配) |
| ECS Exec の IAM 要件は？ | ssmmessages:* / Resource: * が必須 (AWS 設計上) |
| Karpenter と CA の違いを 3 つ | ①Pod 要件から直接 EC2 選択 ②スケール速度 ③コスト最適化 |
| Pod Identity と IRSA の違いは？ | OIDC Provider 不要 / SA annotations 不要 / クラスター単位の管理 |
| KEDA の SQS トリガーの仕組みは？ | GetQueueAttributes で深度取得 → HPA の externalMetric に変換 |
