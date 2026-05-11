# CLAUDE.md - eks-chaos-cell

## プロジェクト概要

**Cell-Based EKS × AWS FIS カオスエンジニアリング基盤**

AWSが大規模サービスで採用するCell Architectureをミニマムに実装し、
AWS Fault Injection Service（FIS）で意図的に障害を注入して
自己回復能力を実測・可視化するプラットフォーム。

### 解決する問題
- 「可用性設計しました」が数値で証明できない
- AZ障害時の実際の挙動を事前に把握できていない
- Karpenterの自動スケールが本当に機能するか不明

### 実証できること
- AZ障害注入 → Karpenterが別AZにノード再作成するまでの時間
- Pod障害 → PDBとtopologySpreadConstraintsによる分散回復
- Cell間の障害非伝播（blast radiusの限定）

---

## ディレクトリ構造

```
eks-chaos-cell/
├── CLAUDE.md                          # このファイル（Claude Code自動ロード）
├── README.md
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml         # PR時のterraform plan
│       └── chaos-experiment.yml       # FIS実験手動トリガー
├── terraform/
│   ├── backend/                       # S3/DynamoDB/OIDC（bootstrap）
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── modules/
│   │   ├── vpc/                       # VPC・サブネット・NAT GW
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── eks/                       # EKSクラスター本体
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── karpenter/                 # Karpenter EC2NodeClass/NodePool
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   ├── observability/             # AMP/AMG/Container Insights
│   │   │   ├── main.tf
│   │   │   ├── variables.tf
│   │   │   └── outputs.tf
│   │   └── fis/                       # FIS実験テンプレート
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       └── outputs.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── terraform.tfvars.example
├── k8s/
│   ├── cells/
│   │   ├── cell-a/                    # Cell-A（ap-northeast-1a）
│   │   │   ├── namespace.yaml
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   └── pdb.yaml
│   │   └── cell-b/                    # Cell-B（ap-northeast-1c）
│   │       ├── namespace.yaml
│   │       ├── deployment.yaml
│   │       ├── service.yaml
│   │       └── pdb.yaml
│   ├── ingress/
│   │   ├── alb-ingress.yaml           # AWS Load Balancer Controller
│   │   └── target-group-binding.yaml
│   └── monitoring/
│       ├── prometheus-scrape-config.yaml
│       └── grafana-dashboard-configmap.yaml
├── fis/
│   ├── experiments/
│   │   ├── az-outage.json             # AZ障害実験定義
│   │   ├── pod-stress.json            # Pod CPU/Memoryストレス
│   │   └── network-latency.json       # ネットワーク遅延注入
│   └── run_experiment.sh              # FIS実験実行スクリプト
├── scripts/
│   ├── bootstrap.sh                   # EKSセットアップ一括
│   ├── verify_recovery.sh             # 回復時間計測スクリプト
│   └── load_generator.sh              # 負荷生成（hey/k6）
├── docs/
│   ├── architecture.md
│   ├── adr/
│   │   ├── ADR-001-cell-vs-az.md
│   │   ├── ADR-002-karpenter-vs-cas.md
│   │   └── ADR-003-fis-experiment-design.md
│   └── runbook/
│       ├── chaos-experiment-procedure.md
│       ├── recovery-time-measurement.md
│       └── grafana-dashboard-guide.md
└── results/
    └── experiment-results.md          # 実測値記録（面接で提示）
```

---

## 技術スタック

| カテゴリ | 技術 |
|----------|------|
| コンテナ基盤 | Amazon EKS 1.31（Managed Node Group → Karpenter移行） |
| ノード自動管理 | Karpenter v1.0（EC2NodeClass + NodePool） |
| ネットワーク | VPC CNI（aws-node）・AWS Load Balancer Controller |
| 障害注入 | AWS Fault Injection Service（FIS） |
| 観測 | Amazon Managed Prometheus・Amazon Managed Grafana |
| コンテナ観測 | CloudWatch Container Insights |
| IaC | Terraform >= 1.9（モジュール構成） |
| CI/CD | GitHub Actions（OIDC認証） |
| リージョン | ap-northeast-1（AZ: 1a・1c の2Cell構成） |
| 通知 | Chatwork（実験開始・完了・異常アラート） |

---

## 設計原則

### Cell Architectureの核心
- **Blast Radius限定**: Cell-Aの障害がCell-Bに伝播しない
- **独立性**: 各CellはNamespace・NodePool・ALB Target Groupが独立
- **等価性**: Cell間でワークロードは同一仕様（スケールのみ異なる）

### Karpenter設計
- **AZ固定NodePool**: Cell-AはAZ-a専用・Cell-BはAZ-c専用のNodePoolを使用
- **arm64優先**: Graviton3（m7g系）をデフォルトとしコスト最適化
- **スポットと混在**: On-Demand:Spot = 1:2 の比率でコスト削減

### セキュリティ
- **IRSA必須**: Pod単位のIAMロール。ノードにiam:*権限を与えない
- **OIDC必須**: GitHub ActionsからAWSへのアクセスはOIDCのみ
- **最小権限**: FIS実行ロールはec2:StopInstances対象を実験タグ付きに限定

### コスト管理
- EKSクラスター: $0.10/h = $73/月
- Karpenter管理ノード: 実験時のみ起動（平時は最小2台）
- 月額目標: $150以下（EKS込み）
- 実験後はノードをscale-downしてコスト抑制

---

## フェーズ実行方法

```bash
# プロジェクトディレクトリで順番に実行
claude < phase1.md
claude < phase2.md
claude < phase3.md
claude < phase4.md
claude < phase5.md
claude < phase6.md
```

各フェーズは前フェーズの成果物サマリーを冒頭に含む。
必ず順番通りに実行すること。

---

## 環境変数・シークレット

```bash
# GitHub Actions Secrets
AWS_ACCOUNT_ID           # AWSアカウントID
CHATWORK_API_TOKEN       # Chatwork通知用
CHATWORK_ROOM_ID         # 通知先ルームID

# ローカル作業用（~/.aws/credentials または環境変数）
AWS_PROFILE=eks-chaos-cell
AWS_DEFAULT_REGION=ap-northeast-1
```

---

## ローカル前提ツール

```bash
# 必須
aws --version          # AWS CLI v2
terraform --version    # >= 1.9
kubectl version        # >= 1.28
helm version           # >= 3.14

# 推奨
eksctl version         # EKS操作補助
k9s version            # クラスター可視化
hey --help             # 負荷生成
```

---

## 面接で語れる数値（実験後に記録）

| 指標 | 目標値 | 実測値 |
|------|--------|--------|
| AZ障害 → Karpenter新規ノード起動 | < 3分 | TBD |
| 新規ノード → Pod起動完了 | < 90秒 | TBD |
| ALBヘルスチェック切り替え | < 60秒 | TBD |
| Cell-B への影響（エラー率） | 0% | TBD |
| MTTR（平均回復時間） | < 5分 | TBD |