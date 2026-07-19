# ADR-002: GPU ノード管理戦略 (Karpenter vs Managed Node Group)

## ステータス
承認済み

## コンテキスト
GPU ノードの管理方法として以下を比較した:

| | Managed Node Group | Karpenter |
|-|-------------------|-----------|
| プロビジョニング | 事前設定が必要 | オンデマンド |
| Spot対応 | ○ | ○ (フォールバック容易) |
| インスタンスタイプ | 限定的 | 複数指定可 |
| scale-to-zero | 困難 | 容易 (KEDA連携) |
| コスト | 常時稼働分課金 | 使った分のみ |

## 決定
Karpenter + GPU NodePool (`node-pool-gpu`) を採用。
システムワークロードのみ Managed Node Group を使用。

## 決定理由
<!-- ハンズオン後に記述: Karpenterのプロビジョニング速度を実測してどう感じたか -->
<!-- MNGではなくKarpenterを選んだことでどんな運用上の差異があったか -->

## トレードオフ
- Karpenterのアップグレード管理が追加コストになる
- GPU AMIの選択 (AL2 vs Bottlerocket) は手動で調整が必要
