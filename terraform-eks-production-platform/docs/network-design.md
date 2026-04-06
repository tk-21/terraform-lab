# ネットワーク設計ドキュメント

## CIDR設計の意思決定

### VPC CIDR: 10.0.0.0/16

**なぜ /16 か**

VPCのCIDRは変更できないため、最初から大きく取ることが重要。

| オプション | アドレス数 | 判定 |
|---|---|---|
| /24 | 254 | ❌ サブネット分割で枯渇する |
| /20 | 4,094 | ❌ 将来拡張に不安 |
| /16 | 65,534 | ✅ 採用 |
| /8 | 16,777,214 | ❌ 過剰（他システムとの連携時にルート重複リスク） |

/16（10.0.0.0/16）を採用することで、将来的なAZ追加・用途別サブネット増設に対応できる。

### サブネットCIDR設計

```
VPC: 10.0.0.0/16 (65,534 アドレス)
├── Public AZ-a:    10.0.0.0/24  (254 アドレス)
├── Public AZ-c:    10.0.1.0/24  (254 アドレス)
├── Private AZ-a:   10.0.10.0/23 (510 アドレス)
├── Private AZ-c:   10.0.12.0/23 (510 アドレス)
├── Isolated AZ-a:  10.0.20.0/24 (254 アドレス)
├── Isolated AZ-c:  10.0.21.0/24 (254 アドレス)
└── 予約領域:        その他のアドレス（将来の拡張用）
```

#### Publicサブネット: /24 にした理由

Publicサブネットに配置するリソース:
- Application Load Balancer（最大100前後のIPを使用）
- NAT Gateway（1つのENIを使用）

/24（254アドレス）でALBの拡張分を含めても十分。

#### Privateサブネット: /23 にした理由

**EKS + VPC CNIのIPアドレス消費量**

VPC CNIはPodに対してもVPCのIPアドレスを割り当てるため、ノード数 × Pod数分のIPが消費される。

| 計算根拠 | 値 |
|---|---|
| t3.medium の最大Pod数 | 17 |
| Managed Node Group最大ノード数 | 3 |
| Karpenterノード最大 | 10 |
| 合計ノード数 | 13 |
| 必要IPアドレス数（ノード + Pod） | 13 × (1 + 17) = 234 |
| バッファ（2倍） | 468 |

/23（510アドレス）とすることで現状の468アドレスに加え、将来のスケールアウトに対応できる。
/24（254アドレス）では余裕がない。

#### Isolatedサブネット: /24 にした理由

RDS・ElastiCacheはインスタンス数が少なく（Multi-AZで2～4インスタンス程度）、IPを多く消費しないため/24で十分。

### AZ数: 2 にした理由

| オプション | コスト | 可用性 |
|---|---|---|
| 1 AZ | 安い | 単一障害点あり |
| 2 AZ | 中（NAT GW ×2） | AZ障害を耐える |
| 3 AZ | 高い | より高可用性 |

東京リージョンは通常1aと1cのAZが利用されることが多い。
本番でのAZ障害は年に数回あるため、2AZ構成でAZ障害対応を確保する。
3AZ構成はリソースコストが1.5倍になるため、このプロジェクトでは2AZを採用。

---

## VPC Endpointを使う理由

### コスト面

```
コンテナイメージのPull（ECR）:
- NAT Gateway経由: データ転送コスト $0.045/GB × 転送量
- VPC Endpoint経由: 追加のデータ転送コストなし（Endpoint料金は$0.01/時間）
```

Karpenterがスポットインスタンスを起動するたびにOSとコンテナイメージをPullする。
1GB/回 × 100回/月 = 100GB → NAT経由だと $4.5/月の転送コスト発生。
ECR Endpointを使うと、この転送コストがなくなる。

### セキュリティ面

| 比較項目 | NAT Gateway経由 | VPC Endpoint経由 |
|---|---|---|
| 通信経路 | インターネット経由 | AWS内部ネットワーク |
| 通信の盗聴リスク | あり（HTTPS で保護） | なし（VPC内完結） |
| エンドポイント制限 | 不可 | IAMポリシーで制限可能 |

### 各Endpointの使用用途

| Endpoint | タイプ | 使用理由 |
|---|---|---|
| S3 | Gateway | ECRイメージレイヤーはS3に保存されている。Gateway型は無料でルートテーブルに設定される |
| ECR API | Interface | `docker login` に相当するECR認証APIのVPC内完結 |
| ECR DKR | Interface | コンテナイメージのPull（レイヤーダウンロード）のVPC内完結 |
| Secrets Manager | Interface | PodからSecrets Managerで機密情報を取得する際のVPC内完結 |
| STS | Interface | IRSAのAssumeRoleWithWebIdentityのVPC内完結 |
| CloudWatch Logs | Interface | Container InsightsのログをVPC内で送信 |

---

## 3層分離の設計思想

### なぜIsolatedサブネットが必要か

**Privateサブネットのみでは不十分な理由**

EKSノードとRDBSが同じPrivateサブネットにいる場合、セキュリティグループの設定ミスでノードから直接DBに接続できてしまうリスクがある。

```
【問題のある構成（2層）】
Private Subnet:
  EKS Node → DB（設定ミスで直接アクセス可能）

【セキュアな構成（3層）】
Private Subnet: EKS Node
Isolated Subnet: RDS
→ Isolatedはルートテーブルにデフォルトルートなし
→ ネットワークレベルでインターネットへの経路が存在しない
```

**Isolated vs Privateの違い**

| 特性 | Private | Isolated |
|---|---|---|
| インターネットアクセス | NAT GW経由でアウトバウンドのみ | 完全遮断 |
| 主な用途 | EKS, Lambda | RDS, ElastiCache |
| セキュリティ強度 | 中 | 高 |

### NAT Gatewayの配置設計

**AZごとにNAT Gatewayを配置する理由（本番環境）**

```
AZ-aのNAT GWが停止した場合:
- Single NAT GW構成: AZ-a, AZ-cのPrivateサブネット両方が外部通信不可
- Per-AZ NAT GW構成: AZ-aのPrivateサブネットのみ影響（AZ-cは正常稼働）
```

コスト削減のために検証環境では `enable_nat_gateway_per_az = false` で1つのNAT GWに削減できる。
本番環境では高可用性を優先して各AZに配置する。

**コスト計算**
- NAT Gateway: 約$0.062/時間 × 24時間 × 30日 = **約$44.6/月/個**
- 2AZ構成では**約$89/月**

---

## セキュリティグループ設計

### 最小権限原則の適用

```
【VPC Endpoint SG】
Inbound:  VPC CIDR (10.0.0.0/16) → TCP 443のみ
Outbound: 全許可（AWS APIへの応答）

【EKS Cluster SG】
Inbound:  Node SG → TCP 443のみ（APIサーバーへのアクセス）

【EKS Node SG】
Inbound:  ノード間 全許可（Pod間通信）
          Cluster SG → 全許可（コントロールプレーンからの管理通信）
Outbound: 全許可（NAT GW経由でAWSサービスアクセス）
```

インバウンドルールで `0.0.0.0/0` を許可するのはALBのSGのみ。
ALBのSGはHTTP(80) / HTTPS(443)のみを許可する。
