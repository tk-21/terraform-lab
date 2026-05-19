# ADR-004: カスタムPrivateLinkの設計判断

## ステータス
採用

## コンテキスト
HubがホストするWebサービス（Nginx）をSpokeに安全に公開したい。

## 決定
**PrivateLink（NLB + VPC Endpoint Service）を採用する**

## PrivateLinkとVPC Peeringの本質的な違い

| 観点 | VPC Peering | PrivateLink |
|---|---|---|
| 通信方向 | 双方向（お互いのVPC全体にルーティング） | 単方向（公開サービスのみ） |
| CIDRオーバーラップ | 不可 | 可（関係ない） |
| 公開粒度 | VPC全体 | 特定サービス（NLBポート）のみ |
| コスト | 無料（転送量のみ） | $0.014/時/AZ + 処理データ量 |
| ユースケース | 社内VPC間の自由な通信 | SaaSモデル・最小権限サービス公開 |

## NLBが必要な理由

PrivateLinkはバックエンドとしてNLBまたはGLBを要求する。

理由:
1. **IPアドレスの固定**: NLBはENIに固定IPを割り当てる。
   PrivateLinkはそのIPをConsumer側ENIのルーティング先として使用する。
2. **ヘルスチェック**: NLBが背後のEC2の健全性を確認する。
   不健全なターゲットへのルーティングを回避できる。
3. **スケーラビリティ**: EC2が増えてもNLBがトラフィックを分散する。

## acceptance_required = false の採用理由
学習用途のため承認フロー不要。
本番では `true` にし、`aws ec2 accept-vpc-endpoint-connections` で手動承認する。
