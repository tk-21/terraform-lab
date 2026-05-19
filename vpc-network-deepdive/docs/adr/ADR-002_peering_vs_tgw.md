# ADR-002: VPC PeeringをTransit Gatewayの代わりに採用する理由

## ステータス
採用（学習目的のトレードオフとして意図的に選択）

## コンテキスト
Hub-Spoke構成の相互接続手段として、以下の2択があった：
1. VPC Peering（Peeringのみ）
2. Transit Gateway（TGW）

## 決定
**VPC Peering を採用する**

## 理由

### VPC Peeringを選んだ理由
1. **ネットワークルーティングの基礎を体験できる**
   - PeeringはRoutableでない（Non-transitive）
   - ルートテーブルへの明示的な追記が必要 → ルーティングの本質を学べる
   - TGWはこれを抽象化してしまう

2. **コスト**
   - Peering接続自体は無料（データ転送料はかかる）
   - TGWは $0.05/時/Attachment = 2 Attachment × 24h × 30日 = $72/月 → 予算オーバー

3. **Spoke数が少ない**
   - Spoke 2本程度ならPeeringで管理可能（Spoke 10本超えたらTGWが現実的）

### VPC Peeringの本質的な限界（TGWが必要になるケース）
- **Non-transitive**: Hub→Prod→DevのようなSpoke間転送は不可
- **N対N問題**: Spoke 10本の場合、フルメッシュで45 Peering接続が必要
- **オーバーラップCIDR不可**: Spoke間でCIDRが重複するとPeering設定自体ができない

## 結論
学習目的では「制約を体験すること」自体に価値がある。
TGWへの移行パスは別プロジェクト（transit-gateway-deepdive）で扱う予定。
