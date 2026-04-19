# ADR 002: Karpenter vs Managed Node Group

## ステータス

承認済み

## コンテキスト

EKS のノードプロビジョニング方式として以下がある：

1. **Managed Node Group**
2. **Karpenter**
3. **Self-managed Node Group**

## 決定

Karpenter を採用する（選択肢 2）。

## 理由

- **Golden AMI との統合**: EC2NodeClass で AMI ID を直接指定できる
- **Spot 対応**: binpacking による効率的なスポットインスタンス活用
- **コスト削減**: Graviton(arm64) + Spot で Managed Node Group 比 最大 60% 削減
- **柔軟性**: CPU/メモリ要件に応じたインスタンスタイプの動的選択

## トレードオフ

- Karpenter 自体の運用が必要（Helm 管理）
- Managed Node Group より学習コストが高い

## 決定後の設計

- `expireAfter: 168h` でノードを 7 日ごとに入れ替え（最新 Golden AMI 適用を強制）
- `consolidationPolicy: WhenUnderutilized` でコスト最適化
