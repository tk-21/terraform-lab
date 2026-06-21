# ADR 004 — NAT Gateway を使わない設計

## ステータス
採用

## 背景
[ECS Fargate がプライベートサブネットにいて ECR/S3 に繋ぐ方法として
 NAT Gateway と VPC Endpoint の2択があった経緯]

## 決定
NAT Gateway を廃止し VPC Endpoint に全面移行する

## 理由
[コスト試算や実際の設定で気づいたことを書く]

## トレードオフ
[VPC Endpoint の制限: Interface Endpoint のコスト、対応サービスの制限など]

## 代替案
- NAT Gateway (月額 ~$32)
- NAT インスタンス (EC2 セルフ管理)
