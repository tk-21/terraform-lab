# ECS/EKS Deep Dive Lab — CLAUDE.md

## プロジェクト概要

同一ワークロード（FastAPI ジョブ API + SQS Worker）を **ECS** と **EKS** の両方にデプロイし、
スケーリング挙動・運用手順・コストを実測データで比較する。

インタビューで「ECS と EKS、どちらを選ぶか？なぜか？」を  
実体験 × 定量データで即答できるレベルを目標とする。

---

## 技術的深掘りポイント（このラボで証明する理解）

### ECS 側

| 項目 | 表面的なレベル | このラボのレベル |
|------|--------------|----------------|
| キャパシティプロバイダー | "FARGATE_SPOT を使った" | base/weight 計算で保証タスク数を制御、分配の数学を説明できる |
| サービス間通信 | Cloud Map DNS を使った | Service Connect で Envoy サイドカー不要のメッシュ機能を実装 |
| タスク配置 | デフォルト | spread(AZ) + binpack(CPU) の組み合わせ理由を説明できる |
| デバッグ | ログ確認のみ | ECS Exec の IAM/SSM 要件を理解しシェルアクセス |
| 停止処理 | なし | SIGTERM ハンドラー + stopTimeout で処理中メッセージを保護 |

### EKS 側

| 項目 | 表面的なレベル | このラボのレベル |
|------|--------------|----------------|
| ノードスケーリング | Cluster Autoscaler | Karpenter NodePool の disruption budget と consolidation を設定 |
| IAM 認証 | OIDC IRSA | Pod Identity（2023 新方式）の利点と違いを説明できる |
| スケーリング戦略 | HPA（CPU/Memory） | KEDA の SQS キュー深度トリガー + minReplicaCount=0 |
| Pod 配置 | なし | topologySpreadConstraints で AZ 分散を明示制御 |
| 運用安全性 | なし | PodDisruptionBudget × Karpenter consolidation budget の連携 |

---

## アーキテクチャ

```
Internet
    │
    ▼
[ALB: Public Subnet]
    │
    ├───────────────────────────────────────┐
    │                                       │
    ▼                                       ▼
[ECS Cluster]                          [EKS Cluster]
│                                      │
├─ API Service                         ├─ API Deployment
│   Fargate(base=1) + Spot(weight=4)   │   Karpenter arm64 Spot
│   Service Connect → api:8080         │   topology spread + PDB
│                                      │
└─ Worker Service                      └─ Worker Deployment
    Fargate Spot (SIGTERM ハンドラー)       KEDA ScaledObject (minReplicas=0)
    StepScaling on SQS depth               queueLength=5 per replica
         │                                              │
         └──────────────────┬───────────────────────────┘
                            │
                      [SQS Queue]（共通インフラ）
                      deepdive-job-queue
```

---

## 必須制約（全フェーズ共通、遵守すること）

| 制約 | 値/方針 |
|------|---------|
| NAT Gateway | **1 台のみ**（ap-northeast-1a）EKS アドオン・Karpenter/KEDA イメージ取得のため |
| VPC Endpoint | ECR API/DKR, S3(GW), CloudWatch Logs, SSM, SSMMESSAGES, EC2MESSAGES, STS, SQS, EC2 |
| IAM 権限 | ワイルドカード禁止・最小権限、ロール名 ≤ 64 文字 |
| Terraform | `for_each` over `count`、コメントは日本語で「なぜ」を説明 |
| コンピューティング | arm64/Graviton2 統一（Lambda 含む） |
| ECS | FARGATE_SPOT をデフォルト使用 |
| Secrets | SSM Parameter Store のみ（ハードコード禁止） |
| Python | 3.12 + structlog（ECS/EKS は Lambda Powertools ではなく structlog） |
| リージョン | ap-northeast-1 固定 |

> **NAT Gateway 注記**: 本番では ECR pull-through cache + VPC Endpoint に置き換える。
> ラボではアドオンイメージ取得コスト vs 設定複雑性のトレードオフで NAT を採用。ADR-001 に記載。

---

## ディレクトリ構成

```
ecs-eks-deepdive-lab/
├── CLAUDE.md               ← このファイル
├── phase1.md               ← Phase 1: 共通基盤（VPC, ECR, SQS, App Build）
├── phase2.md               ← Phase 2: ECS Deep Dive
├── phase3.md               ← Phase 3: EKS Deep Dive
├── phase4.md               ← Phase 4: 可観測性 + ロードテスト
├── phase5.md               ← Phase 5: ADR + Interview Prep + Cleanup
├── terraform/
│   ├── foundation/         ← 共通インフラ（VPC, Endpoints, SQS, ECR, IAM）
│   ├── ecs/                ← ECS Cluster, Services, Scaling
│   └── eks/                ← EKS Cluster, Karpenter, Addons IAM
├── app/
│   ├── api/                ← FastAPI アプリ
│   └── worker/             ← SQS ワーカー
├── k8s/
│   └── manifests/          ← Kubernetes マニフェスト
├── docs/                   ← ADR, Runbook, STAR Q&A
└── scripts/                ← ロードテスト, ユーティリティ
```

---

## フェーズ概要

| Phase | 目的 | 主要リソース | 所要時間目安 |
|-------|------|------------|------------|
| 1 | 共通基盤構築 + App Build | VPC, Endpoints, SQS, ECR, Docker | 45 分 |
| 2 | ECS 深掘り | ECS Cluster, Service Connect, ECS Exec, Scaling | 60 分 |
| 3 | EKS 深掘り | Karpenter, Pod Identity, KEDA, LBC | 90 分 |
| 4 | 可観測性 + 計測 | Container Insights, Dashboard, Load Test | 45 分 |
| 5 | まとめ | ADR, Runbook, STAR, Cleanup | 30 分 |

---

## 実行方法

```bash
# プロジェクトルートで各フェーズを実行
cd ecs-eks-deepdive-lab
claude < phase1.md
claude < phase2.md
claude < phase3.md
claude < phase4.md
claude < phase5.md
```

---

## 主要設定値

```
AWS Region:         ap-northeast-1
VPC CIDR:          10.0.0.0/16
Public Subnets:    10.0.0.0/24 (1a), 10.0.1.0/24 (1c)     ← ALB 用
Private Subnets:   10.0.128.0/24 (1a), 10.0.129.0/24 (1c)  ← Compute 用
EKS Version:       1.30
Karpenter Version: v1.0.0（最新版を確認して使用）
App Port:          8080
SQS Visibility:    300 秒（ワーカー処理時間の最大 5 分に余裕）
Project Name:      deepdive
```

---

## 各フェーズ終了後の口頭説明チェック（5 分）

- Phase 2: 「base=1, weight=4 で 6 タスク起動したとき Fargate と Spot の内訳は？」
- Phase 3: 「Karpenter と Cluster Autoscaler の違いを 3 つ挙げよ」
- Phase 4: 「ECS と EKS でスケーリング速度が違った理由は？」
- Phase 5: 「Pod Identity と OIDC IRSA、新規プロジェクトではどちらを選ぶか？」