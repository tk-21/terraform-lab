# Architecture - eks-chaos-cell

> Cell-Based EKS × AWS FIS カオスエンジニアリング基盤の完全理解ドキュメント

---

## 目次

1. [プロジェクト全体像](#1-プロジェクト全体像)
2. [ネットワーク構成](#2-ネットワーク構成)
3. [EKSクラスター構成](#3-eksクラスター構成)
4. [Cell Architecture詳細](#4-cell-architecture詳細)
5. [Karpenter自動スケーリング](#5-karpenter自動スケーリング)
6. [ワークロード設計](#6-ワークロード設計)
7. [トラフィック経路（ALB）](#7-トラフィック経路alb)
8. [FISカオス実験](#8-fisカオス実験)
9. [観測基盤](#9-観測基盤)
10. [IAM・セキュリティ設計](#10-iamセキュリティ設計)
11. [CI/CD パイプライン](#11-cicd-パイプライン)
12. [Terraform構成](#12-terraform構成)
13. [カオス実験フロー（AZ障害）](#13-カオス実験フローaz障害)
14. [コスト設計](#14-コスト設計)

---

## 1. プロジェクト全体像

### 何を作ったのか

「AZ（アベイラビリティゾーン）が丸ごと落ちても、もう片方のAZのサービスは無傷」  
この設計が本当に機能することを **AWS FIS（Fault Injection Service）で実測・証明する** 基盤。

```
┌─────────────────────────────────────────────────────────────────────┐
│                         インターネット                                │
└──────────────────────────────┬──────────────────────────────────────┘
                               │
                    ┌──────────▼──────────┐
                    │    AWS ALB (公開)    │  ← internet-facing
                    │  ヘルスチェック 10秒  │
                    └────┬──────────┬─────┘
                         │          │  50% / 50% ルーティング
              ┌──────────▼──┐  ┌───▼──────────┐
              │   Cell-A    │  │    Cell-B    │
              │  (AZ: 1a)   │  │  (AZ: 1c)   │
              │  nginx×4    │  │  nginx×4    │
              │  PDB: min2  │  │  PDB: min2  │
              └──────────────┘  └─────────────┘
                    ↕ Karpenter管理           ↕ Karpenter管理
              ┌──────────────┐  ┌─────────────┐
              │ NodePool-A   │  │ NodePool-B  │
              │ (AZ-a固定)   │  │ (AZ-c固定)  │
              │ EC2: m7g/t4g │  │ EC2: m7g/t4g│
              └──────────────┘  └─────────────┘

       ┌───────────────────────────────────────────┐
       │         AWS Fault Injection Service        │
       │  ① AZ障害（EC2停止）   chaos-cell=cell-a  │
       │  ② CPUストレス          50%ターゲット       │
       │  ③ ネットワーク遅延     200ms注入           │
       └───────────────────────────────────────────┘
                               │ 実験結果を観測
       ┌───────────────────────▼───────────────────┐
       │              観測スタック                   │
       │  AMP (Prometheus) → AMG (Grafana)          │
       │  ADOT Collector → CloudWatch Container     │
       └───────────────────────────────────────────┘
```

### 技術スタック早見表

| 層 | 技術 | バージョン | 役割 |
|----|------|-----------|------|
| コンテナ基盤 | Amazon EKS | 1.31 | マネージドKubernetes |
| ノード管理 | Karpenter | v1.0.0 | EC2自動起動・削除 |
| CNI | VPC CNI (aws-node) | EKSアドオン | Pod→EC2直接IPアドレス |
| LB | AWS Load Balancer Controller | Helm | ALB自動プロビジョニング |
| 障害注入 | AWS FIS | - | 3種類の実験テンプレート |
| メトリクス | Amazon Managed Prometheus | - | Prometheus互換ストレージ |
| ダッシュボード | Amazon Managed Grafana | - | リアルタイム可視化 |
| コレクター | ADOT (OpenTelemetry) | EKSアドオン | メトリクス収集・転送 |
| IaC | Terraform | >= 1.9 | 全リソースコード管理 |
| CI/CD | GitHub Actions + OIDC | - | アクセスキー不使用 |
| リージョン | ap-northeast-1 | - | AZ: 1a (Cell-A), 1c (Cell-B) |

---

## 2. ネットワーク構成

### VPC・サブネット設計

```
VPC: 10.0.0.0/16 (ap-northeast-1)
│
├── パブリックサブネット (ALB配置)
│   ├── pub-1a: 10.0.0.0/24  (ap-northeast-1a)
│   │           タグ: kubernetes.io/role/elb=1
│   └── pub-1c: 10.0.1.0/24  (ap-northeast-1c)
│               タグ: kubernetes.io/role/elb=1
│
├── プライベートサブネット (EC2/Pod配置)
│   ├── priv-1a: 10.0.10.0/24 (ap-northeast-1a) ← Cell-A ノード
│   │            タグ: karpenter.sh/discovery=eks-chaos-cell-prod
│   │            タグ: availability-zone=ap-northeast-1a  ← EC2NodeClass が参照
│   └── priv-1c: 10.0.11.0/24 (ap-northeast-1c) ← Cell-B ノード
│                タグ: karpenter.sh/discovery=eks-chaos-cell-prod
│                タグ: availability-zone=ap-northeast-1c
│
├── NAT Gateway: AZ-a に 1台 (コスト最適化)
│   └── EIP → パブリックサブネット pub-1a
│
└── Internet Gateway: VPC全体
```

**設計ポイント:** `availability-zone` タグがKarpenterの `subnetSelectorTerms` で参照され、  
Cell-AはAZ-aのサブネットのみ、Cell-BはAZ-cのサブネットのみにEC2が起動することを保証する。

### セキュリティグループ構成

```
┌─────────────────────────────────────────┐
│  SG: eks-chaos-cell-prod-nodes-sg       │
│  タグ: karpenter.sh/discovery=...        │
│                                         │
│  Inbound:  ALL PROTOCOL  ← 同SG内      │ ← ノード間通信全許可（Pod-to-Pod含む）
│  Outbound: ALL PROTOCOL  → 0.0.0.0/0   │ ← 外部通信全許可
└─────────────────────────────────────────┘
```

---

## 3. EKSクラスター構成

### 全体構成

```
EKS Cluster: eks-chaos-cell-prod (Kubernetes 1.31)
│
├── Control Plane (AWS管理)
│   ├── kube-apiserver    ← ログ: audit, api
│   ├── etcd
│   ├── kube-scheduler
│   └── kube-controller   ← ログ: controllerManager
│
├── Managed Node Group (システムノード)
│   ├── インスタンス: t4g.medium (arm64, Graviton2)
│   ├── AMI: AL2_ARM_64
│   ├── 配置: AZ-a のみ (コスト最適化)
│   ├── スケール: min=2, desired=2, max=4
│   ├── ラベル: role=system, node.kubernetes.io/purpose=system
│   ├── タグ: chaos-target=false  ← FIS実験対象外
│   └── 用途: Karpenterコントローラー・CoreDNS・ALB Controller
│
└── Karpenter管理ノード (動的)
    ├── Cell-A NodePool → AZ-a の EC2 (m7g/m6g/t4g 系)
    └── Cell-B NodePool → AZ-c の EC2 (m7g/m6g/t4g 系)
```

### EKS IAMロール構成

```
┌──────────────────────────────────────────────────────────┐
│  EKSクラスター IAMロール (eks-chaos-cell-prod-cluster-role)│
│  AmazonEKSClusterPolicy (AWS管理ポリシー)                 │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  ノードグループ IAMロール (eks-chaos-cell-prod-node-role)  │
│  ├── AmazonEKSWorkerNodePolicy                           │
│  ├── AmazonEKS_CNI_Policy                               │
│  ├── AmazonEC2ContainerRegistryReadOnly                  │
│  └── AmazonSSMManagedInstanceCore  ← FIS SSM実験用       │
└──────────────────────────────────────────────────────────┘
```

**SSMManagedInstanceCoreがポイント:** FISのCPUストレス・ネットワーク遅延実験はSSM Run Commandで  
コマンドを注入する。このポリシーがないとFIS実験がEC2に届かない。

---

## 4. Cell Architecture詳細

### なぜCell Architectureか

```
【AZ分散だけの場合（問題あり）】

  Node-1 (AZ-a)        Node-2 (AZ-c)
  ┌───────────┐         ┌───────────┐
  │ app-pod-1 │         │ app-pod-2 │
  │ app-pod-3 │         │ app-pod-4 │
  └───────────┘         └───────────┘
      ↕ Karpenter Consolidation
      両AZのPodを同時に退避する可能性あり → サービス断
      Blast Radiusが不明確

【Cell Architectureの場合（このプロジェクト）】

  Cell-A (AZ-a)              Cell-B (AZ-c)
  ┌─────────────────┐         ┌─────────────────┐
  │ NodePool-A      │         │ NodePool-B      │
  │ ┌─────────────┐ │         │ ┌─────────────┐ │
  │ │ app-pod × 4 │ │         │ │ app-pod × 4 │ │
  │ └─────────────┘ │  完全   │ └─────────────┘ │
  │ Taint: cell=a   │◄─独立─►│ Taint: cell=b   │
  │ EC2NodeClass-A  │         │ EC2NodeClass-B  │
  └─────────────────┘         └─────────────────┘
  Cell-A全滅 → Cell-Bへの影響: 0%（実測）
```

### Cell隔離の3層構造

```
層1: サブネット隔離
     EC2NodeClass の subnetSelectorTerms で AZ を物理的に固定
     Cell-A: availability-zone=ap-northeast-1a のサブネットのみ
     Cell-B: availability-zone=ap-northeast-1c のサブネットのみ

層2: スケジューリング隔離
     NodePool の Taint/Toleration で Pod の混入を防止
     cell=cell-a:NoSchedule → Cell-A の Toleration を持つ Pod のみスケジュール可

層3: トラフィック隔離
     ALB Target Group が Cell 単位で独立
     Cell-A のヘルスチェック失敗 → Cell-A へのルーティングのみ停止
     Cell-B は継続稼働
```

---

## 5. Karpenter自動スケーリング

### Karpenterコンポーネント構成

```
┌────────────────────────────────────────────────────────────────┐
│  karpenter Namespace (システムノード上で稼働)                    │
│                                                                │
│  ┌──────────────────────────────┐                             │
│  │  Karpenter Controller Pod    │                             │
│  │  IRSA: karpenter-ctrl-role   │──── EC2 RunInstances ──────►│ AWS EC2
│  │  SQS: interruption-queue     │◄─── Spot中断通知 ───────────│ EventBridge
│  └──────────────────────────────┘                             │
│           │ 監視                                               │
│           ▼                                                    │
│  Pending Pod → EC2NodeClass参照 → 最適インスタンス選択・起動    │
└────────────────────────────────────────────────────────────────┘

┌──────────────────────────────┐  ┌──────────────────────────────┐
│  EC2NodeClass: cell-a        │  │  EC2NodeClass: cell-b        │
│  AMI: AL2 (al2@latest)       │  │  AMI: AL2 (al2@latest)       │
│  Subnet: AZ-a のみ           │  │  Subnet: AZ-c のみ           │
│  SG: karpenter.sh/discovery  │  │  SG: karpenter.sh/discovery  │
│  Tag: chaos-target=true      │  │  Tag: chaos-target=true      │
│  Tag: chaos-cell=cell-a      │  │  Tag: chaos-cell=cell-b      │
└──────────────────────────────┘  └──────────────────────────────┘
           ↑ 参照                            ↑ 参照
┌──────────────────────────────┐  ┌──────────────────────────────┐
│  NodePool: cell-a            │  │  NodePool: cell-b            │
│  zone: ap-northeast-1a       │  │  zone: ap-northeast-1c       │
│  arch: arm64 > amd64         │  │  arch: arm64 > amd64         │
│  capacity: on-demand + spot  │  │  capacity: on-demand + spot  │
│  types: m7g/m6g/t4g (med/lg) │  │  types: m7g/m6g/t4g (med/lg) │
│  cpu limit: 20               │  │  cpu limit: 20               │
│  memory limit: 80Gi          │  │  memory limit: 80Gi          │
│  Taint: cell=cell-a:NoSched  │  │  Taint: cell=cell-b:NoSched  │
│  Consolidation: 5min後       │  │  Consolidation: 5min後       │
└──────────────────────────────┘  └──────────────────────────────┘
```

### Spot中断通知フロー

```
EC2 Spot中断発生
      │
      ▼
EventBridge Rule
(EC2 Spot Instance Interruption Warning)
      │
      ▼
SQS Queue: eks-chaos-cell-prod-karpenter-interruption
(メッセージ保持: 5分)
      │
      ▼
Karpenter Controller が受信
      │
      ▼
対象ノードをドレイン → Pod を再スケジュール → 新規EC2を起動
```

EventBridge は3種類のイベントを監視:
- `EC2 Spot Instance Interruption Warning` (2分前通知)
- `EC2 Instance Rebalance Recommendation` (推奨通知)
- `AWS Health Event` (スケジュール変更)

---

## 6. ワークロード設計

### Deployment仕様（Cell-A・Cell-B共通）

```yaml
レプリカ数: 4
コンテナ: nginx:1.27-alpine
ポート: 80

リソース:
  requests: CPU=250m, Memory=128Mi
  limits:   CPU=500m, Memory=256Mi

ヘルスチェック:
  readinessProbe: GET /healthz  (初期5秒, 5秒間隔, 失敗3回でOut)
  livenessProbe:  GET /healthz  (初期15秒, 10秒間隔, 失敗3回で再起動)

グレースフルシャットダウン:
  terminationGracePeriodSeconds: 60秒
```

### Pod配置戦略

```
【topologySpreadConstraints】
maxSkew: 1 / topologyKey: kubernetes.io/hostname / DoNotSchedule

ノードA          ノードB          ノードC
┌──────────┐   ┌──────────┐   ┌──────────┐
│ Pod1     │   │ Pod2     │   │ Pod3     │   Pod4は均等分散
│ Pod4 ??  │   │          │   │          │   maxSkew=1 で
└──────────┘   └──────────┘   └──────────┘   ホスト間の差を1以内に制限
→ DoNotSchedule: 分散できない場合はSchedulingしない（品質保証）

【PodAntiAffinity (preferred)】
同一ホストへの集中を避けるが、必須ではない（柔軟性確保）
```

### PodDisruptionBudget

```
Cell-A PDB:
  minAvailable: 2
  対象: app=app, cell=cell-a

4 Pod 中 2 台を常に保証
  ↓
KarpenterのConsolidationがノードをドレインする際も
PDBの制約内でローリングに退避 → サービス継続

FIS実験でEC2を停止した場合:
  EC2停止 → Pod Pending → Karpenter新規EC2起動
  PDB違反しないようにローリングで再スケジュール
```

---

## 7. トラフィック経路（ALB）

### リクエスト経路全体

```
クライアント
     │ HTTPS/HTTP
     ▼
Internet-facing ALB
  ├── ヘルスチェック: GET /healthz (10秒間隔, タイムアウト5秒)
  ├── ヘルシー閾値: 2回連続成功
  └── アンヘルシー閾値: 3回連続失敗
     │
     │ ルーティング: / → cell-a Service:80
     ▼
Cell-A Service (ClusterIP :80)
  デレジストレーション遅延: 30秒
     │
     ▼
Cell-A Pod × 4 (nginx:1.27-alpine :80)
```

**現状のルーティング:** `/` パス全体が Cell-A にルーティングされる設計。  
Cell-B は Karpenter の NodePool と独立したワークロードを持ち、  
ALB Target Group への登録を追加することで50/50分散が実現できる構成になっている。

### ALB Controller の IRSA フロー

```
kubectl apply -f alb-ingress.yaml
      │
      ▼
ALB Controller (kube-system Namespace)
ServiceAccount: aws-load-balancer-controller
IRSA: eks-chaos-cell-prod-alb-controller ロール
      │ AWS APIコール
      ▼
ALB の自動作成・Target Group 登録・ヘルスチェック設定
```

---

## 8. FISカオス実験

### 安全設計（3層）

```
層1: ターゲットタグで絞り込み
     ┌──────────────────────────────────────┐
     │ chaos-target=true  → 実験対象        │
     │ chaos-target=false → 絶対に触らない  │ ← システムノード
     │ chaos-cell=cell-a  → Cell-A のみ    │
     └──────────────────────────────────────┘

層2: Stop Condition（自動停止）
     ┌──────────────────────────────────────┐
     │ CloudWatch Alarm:                    │
     │   HTTPCode_Target_5XX_Count          │
     │   > 10 回 / 60秒                     │
     │   → FIS実験を即座に自動停止          │
     └──────────────────────────────────────┘

層3: 実験時間の上限
     ┌──────────────────────────────────────┐
     │ SSM Run Command 実験: PT6M (6分)     │
     │ AZ障害実験: EC2停止後は自然完了       │
     └──────────────────────────────────────┘
```

### 実験1: AZ障害（Cell-A EC2全停止）

```
FIS実験テンプレート: aws:ec2:stop-instances

ターゲット:
  ResourceType: aws:ec2:instance
  SelectionMode: ALL（対象全台）
  Filter: chaos-target=true AND chaos-cell=cell-a

実行フロー:
  ① FIS が Cell-A の EC2 を全台停止
         │
  ② ALB ヘルスチェック失敗
     → Cell-A への送信を停止（< 60秒）
         │
  ③ Karpenter がノード消失を検知
     → Cell-A NodePool で新規 EC2 を RunInstances
     → 目標: < 180秒
         │
  ④ 新規 EC2 が Ready
     → PDB に従い Pod を再スケジュール
     → 目標: < 90秒
         │
  ⑤ ALB ヘルスチェック通過
     → Cell-A へのルーティング再開

測定:
  - Cell-B への影響: 0% (実測目標)
  - Karpenter ノード起動時間
  - Pod 完全回復時間
  - ALB 切り替え時間
```

### 実験2: CPUストレス

```
FIS実験テンプレート: aws:ssm:send-command

ターゲット:
  SelectionMode: PERCENT(50) → Cell-A ノードの 50% にのみ適用
  Filter: chaos-target=true AND chaos-cell=cell-a

SSMドキュメント: AWSFIS-Run-CPU-Stress
パラメーター:
  CPU: 0 (全コアを使用)
  DurationSeconds: 300 (5分間)
  InstallDependencies: True (stress-ngを自動インストール)

タイムアウト: PT6M (6分)

測定:
  - CPU スロットリング発生閾値
  - HPA (Horizontal Pod Autoscaler) の動作
  - Pod eviction の有無
```

### 実験3: ネットワーク遅延注入

```
FIS実験テンプレート: aws:ssm:send-command

ターゲット:
  SelectionMode: ALL → Cell-A 全ノード
  Filter: chaos-target=true AND chaos-cell=cell-a

SSMドキュメント: AWSFIS-Run-Network-Latency
パラメーター:
  DelayMilliseconds: 200 (200ms遅延)
  JitterMilliseconds: 50  (±50msジッター)
  DurationSeconds: 300    (5分間)
  Interface: eth0
  InstallDependencies: True (tc コマンドを使用)

タイムアウト: PT6M (6分)

測定:
  - タイムアウト発生閾値
  - ALBヘルスチェックへの影響（タイムアウト5秒）
```

### FIS IAMロール（最小権限設計）

```
FIS Role: eks-chaos-cell-prod-fis-role

許可アクション:
  ec2:StopInstances, ec2:DescribeInstances
    条件: aws:ResourceTag/chaos-target=true (タグ付きのみ)

  ssm:StartAutomationExecution, ssm:GetAutomationExecution,
  ssm:SendCommand, ssm:GetCommandInvocation ... (SSM操作)

  cloudwatch:DescribeAlarms (Stop Condition確認)

  eks:DescribeCluster (クラスター情報取得)

  logs:CreateLogGroup, logs:PutLogEvents
    Resource: /aws/fis/{cluster_name} のみ
```

---

## 9. 観測基盤

### メトリクス収集フロー

```
┌─────────────────────────────────────────────────────────────────┐
│  EKSクラスター内                                                 │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  ADOT Collector Pod (システムノード上)                   │   │
│  │  ServiceAccount: adot-collector@amazon-metrics          │   │
│  │  IRSA: AmazonPrometheusRemoteWriteAccess                │   │
│  │                                                         │   │
│  │  Scrape (15秒間隔):                                      │   │
│  │  ┌─────────────────────────────────────────────────┐   │   │
│  │  │ ① Karpenter :8000/metrics                        │   │   │
│  │  │   → karpenter_nodes_*, karpenter_pods_*,         │   │   │
│  │  │     karpenter_cloudprovider_* をフィルタリング    │   │   │
│  │  │                                                   │   │   │
│  │  │ ② node-exporter (各ノード)                        │   │   │
│  │  │   → CPU/Memory/Disk 使用率                        │   │   │
│  │  │                                                   │   │   │
│  │  │ ③ kubernetes-pods                                 │   │   │
│  │  │   → prometheus.io/scrape=true のPod              │   │   │
│  │  │   外部ラベル: cluster=eks-chaos-cell-prod         │   │   │
│  │  │              region=ap-northeast-1                │   │   │
│  │  └─────────────────────────────────────────────────┘   │   │
│  │                    │ Remote Write                       │   │
│  └────────────────────┼────────────────────────────────────┘   │
│                       │ SigV4署名                              │
└───────────────────────┼─────────────────────────────────────────┘
                        │
                        ▼
        Amazon Managed Prometheus (AMP)
        ワークスペース: eks-chaos-cell-prod-prometheus
        メトリクス保存: 90日
                        │
                        │ QueryMetrics API
                        ▼
        Amazon Managed Grafana (AMG)
        認証: AWS SSO
        データソース: PROMETHEUS + CLOUDWATCH + XRAY
        エンドポイント: EKSとは完全独立（EKS障害中も観測可能）
```

### なぜ AMG をセルフホストしないのか

```
❌ セルフホスト Grafana（EKSクラスター上）の問題:

  EKSクラスター障害
        │
        ▼
  Grafana も同時に落ちる
  → FIS実験中に観測不能になる

✅ Amazon Managed Grafana (AMG) の場合:

  EKSクラスター障害
        │
        × Cell-Aのノードは落ちている
        │
  AMG は EKS とは独立したマネージドサービス
  → FIS実験中もリアルタイムで障害の様子を可視化できる
```

### Grafana IAMロール（読み取り専用）

```
Grafana Role: eks-chaos-cell-prod-grafana-role
Principal: grafana.amazonaws.com

許可アクション:
  AMP: aps:QueryMetrics, aps:GetSeries, aps:GetLabels,
       aps:GetMetricMetadata, aps:ListWorkspaces, aps:DescribeWorkspace
       Resource: AMPワークスペースARNのみ

  CloudWatch: GetMetricData, ListMetrics, DescribeAlarms,
              logs:DescribeLogGroups, logs:GetLogGroupFields,
              logs:StartQuery, logs:GetQueryResults
              Resource: *

  X-Ray: GetTraceSummaries, GetGroups, GetGroup,
         GetTimeSeriesServiceStatistics
         Resource: *
```

### Container Insights

```
CloudWatch Agent → /aws/containerinsights/eks-chaos-cell-prod/performance
ログ保持: 30日

収集データ:
  - Pod CPU/Memory 使用率 (Cell-A/B 別)
  - Node 使用率
  - Cluster 全体サマリー

FIS実験中の観測例:
  Cell-A Pod数:  4 → 0 → 4  (障害→回復)
  Cell-B Pod数:  4 → 4 → 4  (無影響)
```

---

## 10. IAM・セキュリティ設計

### IRSA（Pod単位のIAM）アーキテクチャ

```
IRSA = IAM Roles for Service Accounts
→ ノードのIAMロールを共有せず、Pod単位で個別のIAMロールを割り当てる

┌─────────────────────────────────────────────────────────────────┐
│  EKS OIDC Provider (クラスター固有)                              │
│  https://oidc.eks.ap-northeast-1.amazonaws.com/id/XXXX         │
└───────────────────────────────┬─────────────────────────────────┘
                                │
    ┌───────────────────────────┼──────────────────────┐
    │                           │                      │
    ▼                           ▼                      ▼
Karpenter Controller     ALB Controller         ADOT Collector
ServiceAccount           ServiceAccount         ServiceAccount
karpenter/karpenter      kube-system/alb-ctrl   amazon-metrics/adot
    │                           │                      │
    ▼                           ▼                      ▼
karpenter-ctrl-role      alb-controller-role    adot-collector-role
EC2操作権限              ALB作成・管理権限       AMP書き込み権限
```

### GitHub Actions OIDC

```
GitHub Actions ワークフロー実行
        │ JWT トークン生成
        ▼
GitHub OIDC Provider
https://token.actions.githubusercontent.com
        │ AssumeRoleWithWebIdentity
        ▼
IAM Role: ecc-gha-role
        条件: repo:{github_org}/{github_repo}:*
        │
        ▼
権限:
  S3: tfstate バケットへの読み書き
  DynamoDB: ロックテーブルへのアクセス
  読み取り: EKS・EC2・IAM・KMS の Describe/List のみ

アクセスキー不使用 = 漏洩リスクゼロ
```

---

## 11. CI/CD パイプライン

### terraform-plan.yml の動作

```
PR 作成 (terraform/** に変更あり)
        │
        ▼
GitHub Actions Runner (ubuntu-latest)
        │
        ├── OIDC認証 → AWS ecc-gha-role を Assume
        ├── terraform init
        ├── terraform validate
        └── terraform plan
                │
                ▼
        PR にコメント投稿 (plan結果の末尾3000文字)
        → レビュアーが差分を確認してマージ
        → 実際の apply はローカルで手動実行（CLAUDE.md ポリシー）
```

---

## 12. Terraform構成

### モジュール依存関係

```
terraform/main.tf
    │
    ├──► module "vpc"
    │      outputs: vpc_id, private_subnet_ids, public_subnet_ids
    │
    ├──► module "eks"
    │      inputs:  vpc_id, private_subnet_ids (from vpc)
    │      outputs: cluster_name, cluster_endpoint, oidc_provider_arn,
    │               oidc_issuer, node_group_role_arn, node_group_role_name
    │
    ├──► module "karpenter"
    │      inputs:  cluster_name, cluster_endpoint (from eks)
    │               oidc_provider_arn, oidc_issuer (from eks)
    │               node_group_role_arn, node_group_role_name (from eks)
    │      outputs: (Karpenter設定)
    │
    ├──► module "fis"
    │      inputs:  cluster_name, aws_region, aws_account_id
    │      outputs: experiment_template_ids
    │
    └──► module "observability"
           inputs:  cluster_name, aws_region, aws_account_id
                    oidc_provider_arn, oidc_issuer (from eks)
           outputs: amp_remote_write_url, grafana_endpoint,
                    adot_role_arn
```

### Backend構成（S3 + DynamoDB）

```
S3バケット: eks-chaos-cell-tfstate-{aws_account_id}
  バージョニング: 有効
  暗号化: AES256
  パブリックアクセス: 全ブロック
  削除保護: prevent_destroy

DynamoDB: eks-chaos-cell-tfstate-lock
  ハッシュキー: LockID
  課金: PAY_PER_REQUEST
  用途: 同時 terraform apply を防ぐ排他ロック
```

---

## 13. カオス実験フロー（AZ障害）

### 時系列シーケンス

```
time=0:00  実験開始
           run_experiment.sh が FIS StartExperiment API を呼び出す
           ターゲット: chaos-target=true AND chaos-cell=cell-a

time=0:01  Cell-A の EC2 インスタンスが全台停止
           ┌────────────────────────────────┐
           │  Cell-A: EC2停止               │  ← FIS実行
           │  Cell-B: 正常稼働中            │
           └────────────────────────────────┘

time=0:01  ALB ヘルスチェック失敗開始
           (10秒間隔 × 3回 = 最大30秒でOut-of-Service)
           Cell-A への新規リクエスト送信停止

time=0:01  Karpenter がノード消失を検知
           Cell-A NodePool で新規 EC2 を RunInstances (AZ-a 指定)

time=~1:30 新規 EC2 が Running 状態
           Karpenter がノードを Ready に登録
           Cell-A の Pod が新規ノードへ再スケジュール

time=~2:00 Pod が Ready 状態 (readinessProbe 通過)
           ALB ヘルスチェック通過 → Cell-A へのルーティング再開

time=~3:00 完全回復
           Cell-A: 4 Pod 稼働中
           Cell-B: 0% エラー (障害期間を通じて)
           Grafana: 回復グラフが V字型を示す

           ┌────────────────────────────────────────────┐
           │ run_experiment.sh が以下を記録:              │
           │   - ノード起動時間 (秒)                      │
           │   - Pod 回復時間 (秒)                        │
           │   - Cell-B エラー率 (%)                      │
           │   → results/experiment-{TIMESTAMP}.md に出力 │
           └────────────────────────────────────────────┘
```

### Stop Condition 発火シナリオ

```
予期しない事態で Cell-B にも影響が出た場合:

Cell-B の 5xx エラーが増加
        │ 60秒間で 10回超過
        ▼
CloudWatch Alarm がアクティブ
        │
        ▼
FIS が Stop Condition を検知
        │ 即座に
        ▼
実験を自動停止 (EC2 Stop を中断)
→ Cell-A ノードが再起動 → 実験前の状態に戻す
```

---

## 14. コスト設計

### 月額試算

| リソース | 仕様 | 月額概算 |
|---------|------|---------|
| EKS Control Plane | 1クラスター | ~$73 |
| システムノード | t4g.medium × 2台 (AZ-a, 常時稼働) | ~$14 |
| Karpenter管理ノード | t4g.medium × 2台 (平時最小) | ~$14 |
| NAT Gateway | 1台 + データ転送 | ~$32 |
| AMP | メトリクス保存・クエリ | ~$5 |
| AMG | ワークスペース | ~$9 |
| FIS・ALB・その他 | 実験時のみ | ~$6 |
| **合計** | | **~$153/月** |

### コスト最適化の仕組み

```
平時: Karpenter Consolidation が 5分後に未使用ノードを削除
  → WhenUnderutilized ポリシー

実験時のみ: FIS実験のために Cell-A に Pod を配置
  → Karpenter が必要なときだけ EC2 を起動

インスタンス選択:
  arm64 (Graviton) 優先: x86_64 比で約20%安い
  On-Demand + Spot 混在: Spot でさらに最大70%削減
  優先順: m7g.medium (Graviton3) > m6g.medium > t4g.medium
```

---

## 参照

| ドキュメント | パス |
|------------|------|
| Cell vs AZ分散 の設計判断 | [ADR-001](docs/adr/ADR-001-cell-vs-az.md) |
| Karpenter vs CAS の設計判断 | [ADR-002](docs/adr/ADR-002-karpenter-vs-cas.md) |
| FIS安全設計 | [ADR-003](docs/adr/ADR-003-fis-experiment-design.md) |
| 面接想定Q&A | [interview-qa](docs/runbook/interview-qa.md) |
| 実験結果記録 | [experiment-results](results/experiment-results.md) |
| プロジェクトREADME | [README](README.md) |
