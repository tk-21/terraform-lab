# ADR-002: cluster-autoscaler ではなく Karpenter を採用する

## ステータス

採用（Accepted）

## コンテキスト

EKSのノード自動スケーリングとして以下を検討した。

| ツール | 特徴 |
|--------|------|
| cluster-autoscaler（CAS） | Node Groupベース。AWSの公式推奨（長年の実績） |
| Karpenter | AWSが開発。EC2を直接管理。Node Groupに依存しない |

## 決定

**Karpenter v1.0 を採用する**

## 理由

### Cell Architecture との相性

CASはNode Group単位でスケールする。Cell単位のNodePoolを実現するには
「Cell-A用Node Group」「Cell-B用Node Group」を作る必要があるが、
KarpenterのNodePoolはより細かい条件（AZ・インスタンスタイプ・スポット混在）を
1つのリソースで表現できる。

### スケーリング速度

| 指標 | CAS | Karpenter |
|------|-----|-----------|
| ノード選択 | Node Group内の既存設定に従う | Pendingなポッドの要求に最適なEC2を直接選択 |
| スケールアップ速度 | 2〜3分 | 1〜2分（FIS実験で実測） |
| スポット活用 | Node Group設定依存 | Spot + On-Demand をNodePool内で自動混在 |

### EC2NodeClass の柔軟性

EC2NodeClassでAMI・サブネット・SGを細かく指定できるため、
Cell-AとCell-Bで完全に独立したEC2設定を持てる。

## トレードオフ

- Karpenterはv1.0のため CASより運用事例が少ない
- CRD（EC2NodeClass・NodePool）の学習コストがある
- Karpenter障害時の回避策（CASへのフォールバック）が必要

## 結果

FIS実験でCell-AのEC2が全停止した後、Karpenterが新規ノードを
**平均XX秒**で起動したことを実測で確認（results/参照）。
