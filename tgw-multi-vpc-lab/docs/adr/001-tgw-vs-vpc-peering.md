# ADR-001: VPC PeeringではなくTransit Gatewayを採用する

## ステータス
採用済み

## コンテキスト
4つのVPCを相互接続する方法として、VPC PeeringとTransit Gatewayの2択を検討した。

## 決定
Transit Gatewayを採用する。

## 決定理由
<!-- ここは自分の言葉で記述すること（AI生成禁止） -->
<!-- 考慮すべき観点: VPC数が増えた場合のpeering数の爆発、推移的ルーティングの有無、通信制御の粒度 -->

## トレードオフ
- コスト: TGWはアタッチメント時間とデータ処理量で課金される
- レイテンシ: TGW経由は1ホップ追加される

## 参考
- [Transit Gateway vs VPC Peering](https://docs.aws.amazon.com/vpc/latest/tgw/tgw-peering.html)
