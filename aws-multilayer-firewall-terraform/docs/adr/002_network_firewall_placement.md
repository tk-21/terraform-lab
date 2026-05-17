# ADR 002: Network Firewall の配置場所と AZ 数

## ステータス
承認済み

## コンテキスト

AWS Network Firewall を VPC に導入する際、以下の設計判断が必要だった:

1. Firewall Endpoint を配置する AZ 数（1AZ vs 全AZ）
2. Firewall Subnet を専用サブネットとして切り出すかどうか
3. ルートテーブルのトラフィックルーティングパターン

コスト制約: ハンズオン目的のため月額 $15 以内を目標とする。

## 決定

- **ハンズオン環境**: ap-northeast-1a の 1AZ のみ Firewall Endpoint を配置
- **本番環境**: 全稼働 AZ に Firewall Endpoint を配置する（この ADR では設計を記録するが実装しない）
- Firewall Subnet は /28 の専用サブネットとして分離する
- ルートテーブルは "Sandwich" パターン（IGW → NFW → ALB の順）を採用

## 根拠

### Firewall Subnet を専用サブネット（/28）にする理由

Firewall Endpoint は AWS が管理する ENI（Elastic Network Interface）を
各 AZ に 1 つずつ作成する。この ENI は AWS が占有するため、
他のリソースと同じサブネットに配置すると IP アドレス管理が複雑になる。

/28（16 IP = 使用可能 11 IP）あれば Firewall ENI（1 IP）と
AWS 予約（5 IP）を差し引いても余裕がある。
過剰なアドレス空間を割り当てると他のサブネット設計を圧迫するため最小サイズにした。

### ハンズオンで 1AZ にする理由

| | 1AZ | 2AZ |
|---|---|---|
| Firewall Endpoint コスト | ~$0.395/時間 × 1 = ~$284/月 | ~$0.395/時間 × 2 = ~$568/月 |
| 学習目的での必要性 | ドメインフィルタリング・IPS の動作確認は 1AZ で十分 | 不要 |

ハンズオンでは動作確認ができれば可用性要件は問わないため、
コスト最小化を優先して 1AZ に絞った。

### 本番で全 AZ が必要な理由

Network Firewall の Endpoint は **AZ をまたいだルーティングができない**。
つまり 1a の EC2 からのトラフィックを 1c の Firewall Endpoint に向けることができない。
（AWS は AZ 間通信に追加コストがかかる設計のため）

1AZ に集約した場合、その AZ に障害が発生すると:
1. Firewall Endpoint が応答しなくなる
2. IGW → NFW のルートが dead になる
3. **全 AZ のアウトバウンド通信が断絶する**

本番環境では RTO/RPO 要件を満たすために全 AZ に Endpoint が必要。

### "Sandwich" ルーティングパターンを採用した理由

```
Internet → IGW → [NFW Endpoint] → [Public Subnet/ALB] → [Private Subnet/EC2]
                      ↑ここで L7 フィルタリング
```

IGW に "Ingress Route Table" を設定し、Public Subnet への通信を
一度 NFW Endpoint に向けることで、インバウンド・アウトバウンド両方向を検査できる。

代替案として "Egress only" 構成（Private → NFW → IGW）も検討したが、
それではインバウンドの攻撃トラフィックを検知できないため採用しなかった。

## トレードオフ

| | Sandwich (採用) | Egress only |
|---|---|---|
| インバウンド検査 | ✅ 可能 | ❌ 不可 |
| アウトバウンド検査 | ✅ 可能 | ✅ 可能 |
| ルートテーブル複雑さ | 高（IGW RT + NFW RT + Public RT） | 低 |
| レイテンシ | NFW 経由で +1–2ms 増加 | 同左 |

## ルートテーブル設計（実装参照）

```
IGW Ingress Route Table:
  10.0.0.0/24 → vpce-xxxxxxxx (NFW Endpoint in 1a)
  10.0.1.0/24 → vpce-xxxxxxxx (NFW Endpoint in 1a ← 1AZ構成の限界)

NFW Subnet Route Table:
  0.0.0.0/0 → igw-xxxxxxxx

Public Subnet Route Table:
  0.0.0.0/0 → vpce-xxxxxxxx (NFW Endpoint)
```
