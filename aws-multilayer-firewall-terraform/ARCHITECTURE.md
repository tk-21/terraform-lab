# ARCHITECTURE.md — aws-multilayer-firewall-terraform 完全理解ドキュメント

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [VPC ネットワーク設計](#2-vpc-ネットワーク設計)
3. [多層防御アーキテクチャ全体図](#3-多層防御アーキテクチャ全体図)
4. [ルートテーブル設計（Sandwich パターン）](#4-ルートテーブル設計sandwich-パターン)
5. [セキュリティレイヤー詳細](#5-セキュリティレイヤー詳細)
   - 5.1 [NACL（ネットワーク ACL）](#51-naclネットワーク-acl)
   - 5.2 [Security Group](#52-security-group)
   - 5.3 [AWS Network Firewall](#53-aws-network-firewall)
   - 5.4 [AWS WAF](#54-aws-waf)
6. [トラフィックフロー詳細](#6-トラフィックフロー詳細)
7. [EC2 / SSM 設計](#7-ec2--ssm-設計)
8. [可観測性（ログ設計）](#8-可観測性ログ設計)
9. [Terraform モジュール構成](#9-terraform-モジュール構成)
10. [コスト設計](#10-コスト設計)
11. [セキュリティ設計原則](#11-セキュリティ設計原則)
12. [本番化チェックリスト](#12-本番化チェックリスト)

---

## 1. プロジェクト概要

AWS のネットワークセキュリティ機能を **4 層** 組み合わせ、実際の攻撃をブロックする体験を通じて
各レイヤーの役割と設計判断を身体化するハンズオン。

| フェーズ | 実装内容 | 学習ポイント |
|---|---|---|
| Phase 1 | VPC / SG / NACL | ステートフル vs ステートレス、最小権限 SG |
| Phase 2 | AWS Network Firewall | L7 集中制御、Sandwich ルーティング |
| Phase 3 | AWS WAF | アプリ層防御、マネージドルール活用 |
| Phase 4 | 動作検証 / ADR / ドキュメント | 設計根拠の言語化 |

**前提スペック**

| 項目 | 値 |
|---|---|
| リージョン | ap-northeast-1（東京） |
| Terraform | >= 1.7 |
| AWS プロバイダー | ~> 5.0 |
| リソースプレフィックス | `amf` |
| 月額目標（短期ハンズオン） | $5〜$15 |

---

## 2. VPC ネットワーク設計

### CIDR 設計

```
VPC: 10.0.0.0/16 (65,536 アドレス)
│
├── Public Subnet
│   ├── 10.0.0.0/24  (ap-northeast-1a)  256 addr — ALB, 外部公開リソース
│   └── 10.0.1.0/24  (ap-northeast-1c)  256 addr — ALB (Multi-AZ 必須)
│
├── Private Subnet
│   ├── 10.0.10.0/24 (ap-northeast-1a)  256 addr — EC2, アプリサーバー
│   └── 10.0.11.0/24 (ap-northeast-1c)  256 addr — 将来の拡張用
│
└── Firewall Subnet
    ├── 10.0.100.0/28 (ap-northeast-1a)  16 addr — NFW Endpoint (ハンズオンで使用)
    └── 10.0.101.0/28 (ap-northeast-1c)  16 addr — NFW Endpoint (将来の本番用)
```

### サブネット用途の設計思想

```
┌─────────────────────────────────────────────────────────────────┐
│                        VPC 10.0.0.0/16                         │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Firewall Subnet │  │  Firewall Subnet │                    │
│  │  10.0.100.0/28   │  │  10.0.101.0/28   │                    │
│  │  (1a) ★使用中    │  │  (1c) 将来用     │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Public Subnet   │  │  Public Subnet   │                    │
│  │  10.0.0.0/24     │  │  10.0.1.0/24     │                    │
│  │  (1a)            │  │  (1c)            │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                  │
│  ┌──────────────────┐  ┌──────────────────┐                    │
│  │  Private Subnet  │  │  Private Subnet  │                    │
│  │  10.0.10.0/24    │  │  10.0.11.0/24    │                    │
│  │  (1a) ★EC2       │  │  (1c) 将来用     │                    │
│  └──────────────────┘  └──────────────────┘                    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Firewall Subnet を /28 にした理由**
- Network Firewall Endpoint は AZ ごとに AWS 管理の ENI を 1 つ配置するだけ
- /28（16 IP、うち AWS 予約 5 IP = 使用可能 11 IP）で十分
- 他のリソードと分離することでルーティング管理をシンプルに保つ

---

## 3. 多層防御アーキテクチャ全体図

```
                              Internet
                                 │
                                 │ リクエスト（HTTP/HTTPS）
                                 ▼
                    ┌────────────────────────┐
                    │   Internet Gateway     │
                    │      (amf-igw)         │
                    └────────────────────────┘
                                 │
                    ┌────────────────────────┐ ← IGW Edge Route Table
                    │   ↓ ここがポイント！    │   10.0.0.0/24 → NFW Endpoint
                    │   Ingress トラフィックを│   10.0.1.0/24 → NFW Endpoint
                    │   NFW Endpoint に向ける │
                    └────────────────────────┘
                                 │
                                 ▼
          ┌──────────────────────────────────────────────┐
          │         Firewall Subnet (10.0.100.0/28)      │
          │                                               │
          │   ┌───────────────────────────────────────┐  │
          │   │   AWS Network Firewall Endpoint       │  │ ← [Layer 3] NFW
          │   │           (amf-nfw)                   │  │
          │   │                                       │  │
          │   │  ① Stateless Rules                    │  │
          │   │     ループバック (127.0.0.0/8) → DROP  │  │
          │   │     その他 → Stateful Engine へ転送    │  │
          │   │                                       │  │
          │   │  ② Stateful: ドメインフィルタリング    │  │
          │   │     ALLOWLIST: .amazonaws.com 等       │  │
          │   │     上記以外はすべて DROP (default)    │  │
          │   │                                       │  │
          │   │  ③ Stateful: IPS (Suricata ルール)     │  │
          │   │     SQLi / ディレクトリトラバーサル    │  │
          │   │     Nikto スキャナー検出              │  │
          │   └───────────────────────────────────────┘  │
          └──────────────────────────────────────────────┘
                                 │
                                 ▼
          ┌──────────────────────────────────────────────┐
          │   NACL: amf-nacl-public                      │ ← [Layer 1] NACL
          │   IN:  80, 443, 1024-65535(ephemeral) 許可   │
          │   IN:  22 (SSH) 明示的 DENY                  │
          │   OUT: all (-1) 許可                         │
          └──────────────────────────────────────────────┘
                                 │
          ┌──────────────────────────────────────────────┐
          │         Public Subnet (10.0.0.0/24)          │
          │                                               │
          │   ┌───────────────────────────────────────┐  │
          │   │   ALB (amf-alb)                       │  │
          │   │   SG: amf-sg-web                      │  │ ← [Layer 2] SG
          │   │     IN:  80, 443 ← 0.0.0.0/0          │  │
          │   │     OUT: 8080  → amf-sg-app            │  │
          │   │                                       │  │
          │   │   ┌─────────────────────────────────┐ │  │
          │   │   │   WAF WebACL (amf-waf-alb)      │ │  │ ← [Layer 4] WAF
          │   │   │   Priority 10: IP ブロックリスト  │ │  │
          │   │   │   Priority 20: CRS (OWASP Top10) │ │  │
          │   │   │   Priority 30: Known Bad Inputs   │ │  │
          │   │   │   Priority 40: レートベース 2000  │ │  │
          │   │   │   Priority 50: スキャナー UA      │ │  │
          │   │   │   Default: ALLOW                  │ │  │
          │   │   └─────────────────────────────────┘ │  │
          │   └───────────────────────────────────────┘  │
          └──────────────────────────────────────────────┘
                                 │
          ┌──────────────────────────────────────────────┐
          │   NACL: amf-nacl-private                     │ ← [Layer 1] NACL
          │   IN:  8080 ← 10.0.0.0/23 (Public) のみ     │
          │   IN:  1024-65535 (戻りパケット) 許可         │
          │   OUT: all (-1) 許可                         │
          └──────────────────────────────────────────────┘
                                 │
          ┌──────────────────────────────────────────────┐
          │         Private Subnet (10.0.10.0/24)        │
          │                                               │
          │   ┌───────────────────────────────────────┐  │
          │   │   EC2 (amf-ec2-test)                  │  │
          │   │   t4g.nano / arm64 / AL2023           │  │
          │   │   IMDSv2 強制 / EBS 暗号化             │  │
          │   │   SG: amf-sg-app + amf-sg-ssm         │  │ ← [Layer 2] SG
          │   │     IN:  8080 ← amf-sg-web のみ       │  │
          │   │     OUT: 443  → 0.0.0.0/0 (SSM用)     │  │
          │   └───────────────────────────────────────┘  │
          │                                               │
          │   ┌───────────────────────────────────────┐  │
          │   │   VPC Endpoints (Interface)           │  │
          │   │   - com.amazonaws.*.ssm               │  │
          │   │   - com.amazonaws.*.ec2messages       │  │
          │   │   - com.amazonaws.*.ssmmessages       │  │
          │   │   SG: amf-sg-vpce (443 from VPC only) │  │
          │   └───────────────────────────────────────┘  │
          └──────────────────────────────────────────────┘
                                 │
                    ┌────────────────────────┐
                    │   SSM Session Manager  │ ← SSH レス・22番ポート不使用
                    └────────────────────────┘
```

---

## 4. ルートテーブル設計（Sandwich パターン）

Network Firewall の核心は「**Sandwich ルーティング**」。Ingress と Egress の両方向を
NFW Endpoint に通すことで双方向検査を実現する。

### 3 種類のルートテーブル

```
                     ┌─────────────────────────────────────────────────┐
                     │ A. IGW Edge Route Table (amf-rtb-igw-edge)      │
                     │    Association: Internet Gateway                 │
                     │                                                  │
                     │    10.0.0.0/24 → vpce-xxx (NFW Endpoint 1a)    │
                     │    10.0.1.0/24 → vpce-xxx (NFW Endpoint 1a)    │
                     │                                                  │
                     │    ★ Gateway Association が Ingress 検査の核心  │
                     │      IGW に設定することで、IGW に入った瞬間に   │
                     │      NFW 経由に強制される                       │
                     └─────────────────────────────────────────────────┘

                     ┌─────────────────────────────────────────────────┐
                     │ B. Firewall Subnet Route Table (amf-rtb-fw)     │
                     │    Association: Firewall Subnet (10.0.100.0/28) │
                     │                                                  │
                     │    0.0.0.0/0 → igw-xxx (Internet Gateway)      │
                     │                                                  │
                     │    ★ Firewall Subnet 自身は NFW を通さない      │
                     │      ループを防ぐため IGW 直接ルートが必要      │
                     └─────────────────────────────────────────────────┘

                     ┌─────────────────────────────────────────────────┐
                     │ C. Public Subnet Route Table (amf-rtb-public)   │
                     │    Association: Public Subnet (10.0.0.0/24 etc) │
                     │                                                  │
                     │    0.0.0.0/0 → vpce-xxx (NFW Endpoint 1a)      │
                     │                                                  │
                     │    ★ Egress トラフィックを NFW 経由にする       │
                     │      Phase 1 の IGW 直接ルートをこれに差し替え  │
                     └─────────────────────────────────────────────────┘
```

### トラフィックパスの全体像

```
【Ingress (Internet → EC2)】

Internet
  │
  ▼
IGW (igw-xxx)
  │ ← Edge RT が発動: 10.0.0.0/24 宛てを NFW Endpoint へ
  ▼
NFW Endpoint (vpce-xxx, 10.0.100.x/28)
  │ ← Stateless / Stateful / ドメイン / IPS で検査
  ▼
ALB (Public Subnet 10.0.0.x)
  │ ← WAF で SQLi / XSS / Bot を検査
  ▼
EC2 (Private Subnet 10.0.10.x)


【Egress (EC2 → Internet)】

EC2 (Private Subnet 10.0.10.x)
  │ ← Private RT: 0.0.0.0/0 → Nat GW なし、VPC Endpoint で AWS サービスへ直接
  │   ※ AWS サービス以外への Egress は Public Subnet 経由
  ▼
ALB / Public Subnet (Public RT: 0.0.0.0/0 → NFW Endpoint)
  │
  ▼
NFW Endpoint (vpce-xxx)
  │ ← ドメインフィルタリング: allowlist 外はここで DROP
  ▼
IGW → Internet


【SSM アクセス (ブラウザ/CLI → EC2)】

管理者 (AWS Console or CLI)
  │
  ▼
SSM サービスエンドポイント (AWS グローバル)
  │
  ▼
VPC Interface Endpoint (com.amazonaws.ap-northeast-1.ssm 等)
  │ ← EC2 → VPC Endpoint への 443 アウトバウンドを SSM Agent が維持
  ▼
EC2 (SSM Agent がトンネルを確立)
```

---

## 5. セキュリティレイヤー詳細

### 5.1 NACL（ネットワーク ACL）

**特性**: ステートレス・サブネットレベル・明示的 DENY が書ける

#### amf-nacl-public（Public サブネット用）

```
インバウンドルール（番号の小さい順に評価）:
┌────────┬──────────┬───────────────┬──────────────┬────────┐
│ Rule # │ Protocol │ Port          │ Source       │ Action │
├────────┼──────────┼───────────────┼──────────────┼────────┤
│   100  │ TCP      │ 80            │ 0.0.0.0/0    │ ALLOW  │
│   110  │ TCP      │ 443           │ 0.0.0.0/0    │ ALLOW  │
│   120  │ TCP      │ 1024-65535    │ 0.0.0.0/0    │ ALLOW  │ ← 戻りパケット
│   200  │ TCP      │ 22            │ 0.0.0.0/0    │ DENY   │ ← SSH 明示拒否
│ 32766  │ ALL      │ ALL           │ 0.0.0.0/0    │ ALLOW  │
│ 32767  │ ALL      │ ALL           │ 0.0.0.0/0    │ DENY   │ ← AWS 暗黙の DENY
└────────┴──────────┴───────────────┴──────────────┴────────┘

アウトバウンドルール:
┌────────┬──────────┬──────┬──────────────┬────────┐
│ Rule # │ Protocol │ Port │ Dest         │ Action │
├────────┼──────────┼──────┼──────────────┼────────┤
│   100  │ ALL (-1) │ ALL  │ 0.0.0.0/0    │ ALLOW  │
│ 32767  │ ALL      │ ALL  │ 0.0.0.0/0    │ DENY   │
└────────┴──────────┴──────┴──────────────┴────────┘
```

> **なぜ Rule 120（エフェメラルポート）が必要か？**
> NACL はステートレスなので、EC2 が https://example.com へリクエストした際の
> 応答パケット（送信元ポート: 443 → 宛先ポート: 1024-65535）を明示的に許可しないと
> 応答が届かない。Security Group ではこれが自動的に処理される。

#### amf-nacl-private（Private サブネット用）

```
インバウンドルール:
┌────────┬──────────┬────────────┬──────────────┬────────┐
│ Rule # │ Protocol │ Port       │ Source       │ Action │
├────────┼──────────┼────────────┼──────────────┼────────┤
│   100  │ TCP      │ 8080       │ 10.0.0.0/23  │ ALLOW  │ ← Public サブネットのみ
│   110  │ TCP      │ 1024-65535 │ 0.0.0.0/0    │ ALLOW  │ ← 戻りパケット
│ 32766  │ ALL      │ ALL        │ 0.0.0.0/0    │ ALLOW  │
└────────┴──────────┴────────────┴──────────────┴────────┘
```

> Rule 100 の `10.0.0.0/23` は Public Subnet（10.0.0.0/24 + 10.0.1.0/24）を
> まとめた CIDR。直接インターネットから Private Subnet へのアクセスを
> NACL レベルで遮断する多層防御。

---

### 5.2 Security Group

**特性**: ステートフル・インスタンスレベル・SG 間参照で役割ベース制御

#### SG 構成図（参照関係）

```
                    ┌──────────────────────────────────────┐
                    │   amf-sg-web (ALB / Web 層)          │
                    │                                      │
                    │   IN:  80  TCP ← 0.0.0.0/0          │
                    │   IN:  443 TCP ← 0.0.0.0/0          │
                    │   OUT: 8080 TCP → [amf-sg-app の ID] │ ← SG 参照
                    └──────────────────────────────────────┘
                                       │ 8080
                                       ▼
                    ┌──────────────────────────────────────┐
                    │   amf-sg-app (EC2 / App 層)          │
                    │                                      │
                    │   IN:  8080 TCP ← [amf-sg-web の ID] │ ← SG 参照
                    │   OUT: 443  TCP → 0.0.0.0/0         │
                    └──────────────────────────────────────┘

                    ┌──────────────────────────────────────┐
                    │   amf-sg-ssm (EC2 に付与)            │
                    │                                      │
                    │   IN:  なし（インバウンド不要）        │
                    │   OUT: 443 TCP → 0.0.0.0/0          │ ← SSM Endpoint 向け
                    └──────────────────────────────────────┘

                    ┌──────────────────────────────────────┐
                    │   amf-sg-vpce (VPC Endpoint 用)      │
                    │                                      │
                    │   IN:  443 TCP ← 10.0.0.0/16        │ ← VPC 内からのみ
                    │   OUT: 0.0.0.0/0 全許可              │
                    └──────────────────────────────────────┘
```

#### SG 参照の利点

IP アドレスではなく SG ID で制御するため、Auto Scaling で EC2 が増減しても
ルールの更新が不要。`amf-sg-web の SG が付いているリソースからの 8080` という
意図が明確に表現される。

---

### 5.3 AWS Network Firewall

**特性**: ステートフル・VPC 全体の集中制御・L3-L7 対応・Suricata IPS

#### ルールエンジンの評価フロー

```
受信パケット
     │
     ▼
┌─────────────────────────────────────────────────────┐
│  Stateless ルールグループ (amf-nfw-stateless-rg)     │
│                                                      │
│  Priority 10: 127.0.0.0/8 (ループバック) → DROP      │
│  Priority 100: その他 → Stateful Engine へ転送        │
│                                                      │
│  ★ Stateless は接続追跡なし。パケット単位で処理。    │
└─────────────────────────────────────────────────────┘
     │ aws:forward_to_sfe
     ▼
┌─────────────────────────────────────────────────────┐
│  Stateful Engine (STRICT_ORDER モード)               │
│                                                      │
│  ▼ Priority 10: ドメイン許可リスト (amf-nfw-domain-rg)│
│  │                                                   │
│  │  ALLOWLIST モード（許可リスト方式）:               │
│  │  ✅ .amazonaws.com   (AWS サービス)               │
│  │  ✅ .amazonlinux.com (OS アップデート)            │
│  │  ✅ example.com      (疎通確認用)                 │
│  │  ❌ その他すべて → DROP (ゼロトラスト)            │
│  │                                                   │
│  │  検査対象: HTTP_HOST ヘッダー / TLS SNI           │
│  │                                                   │
│  ▼ Priority 20: IPS ルール (amf-nfw-ips-rg)         │
│     Suricata 互換ルール:                             │
│     sid:1000001 SQL Injection (SELECT + FROM)        │
│     sid:1000002 UNION SELECT                         │
│     sid:1000003 Directory Traversal (../)            │
│     sid:1000004 Nikto Scanner (http_header)          │
│                                                      │
│  ▼ デフォルトアクション: aws:drop_strict             │
│     ★ どのルールにもマッチしないものをすべて DROP    │
└─────────────────────────────────────────────────────┘
```

#### Firewall Policy の設定

```
Policy: amf-nfw-policy

  Stateless:
    default_actions          = ["aws:forward_to_sfe"]  ← 全パケットを Stateful へ
    fragment_default_actions = ["aws:forward_to_sfe"]  ← フラグメントも同様

  Stateful Engine:
    rule_order = "STRICT_ORDER"  ← priority 順に評価（DEFAULT_ACTION_ORDER ではない）
    default_actions = ["aws:drop_strict"]  ← ホワイトリスト方式の核心

  Rule Groups:
    Priority 10: amf-nfw-domain-rg (ドメイン許可リスト)
    Priority 20: amf-nfw-ips-rg    (Suricata IPS)
```

> **STRICT_ORDER vs DEFAULT_ACTION_ORDER**
> STRICT_ORDER は priority 番号の順にルールグループを評価し、
> 最初にマッチしたルールで即決定する（pass なら許可、drop なら破棄）。
> DEFAULT_ACTION_ORDER は全ルールを評価してから最終アクションを決める。
> 本プロジェクトでは予測可能な動作のために STRICT_ORDER を採用。

---

### 5.4 AWS WAF

**特性**: L7 特化・ALB/CloudFront にアタッチ・マネージドルール活用

#### WAF ルール評価順序

```
リクエスト受信
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Priority 10: BlockedIPSet                                       │
│  ──────────────────────────────────────────────────────────────  │
│  条件: aws_wafv2_ip_set.blocked に登録された IP から来るリクエスト │
│  アクション: BLOCK (即 403)                                       │
│  用途: Threat Intel フィードからの既知悪意 IP を最速でブロック    │
└─────────────────────────────────────────────────────────────────┘
     │ PASS
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Priority 20: AWSManagedRulesCRS (Core Rule Set)                 │
│  ──────────────────────────────────────────────────────────────  │
│  ルールセット: AWSManagedRulesCommonRuleSet (700 WCU)            │
│  アクション: BLOCK (ただし SizeRestrictions_BODY のみ COUNT)      │
│  用途: OWASP Top 10 を幅広くカバー（SQLi / XSS / LFI 等）        │
│                                                                   │
│  SizeRestrictions_BODY を COUNT にしている理由:                   │
│    大容量 POST（ファイルアップロード等）の正規リクエストが誤検知    │
│    される可能性があるため、一定期間観察してから BLOCK に切り替える │
└─────────────────────────────────────────────────────────────────┘
     │ PASS
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Priority 30: AWSManagedRulesKnownBadInputs (200 WCU)           │
│  ──────────────────────────────────────────────────────────────  │
│  アクション: BLOCK                                                │
│  用途: Log4Shell (CVE-2021-44228) / Spring4Shell 等の既知エクスプロイト │
└─────────────────────────────────────────────────────────────────┘
     │ PASS
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Priority 40: RateLimitRule (2 WCU)                              │
│  ──────────────────────────────────────────────────────────────  │
│  条件: 同一 IP から 5 分間で 2000 リクエスト超                    │
│  アクション: BLOCK                                                │
│  用途: DDoS / クレデンシャルスタッフィング / スクレイピング抑制    │
│  閾値根拠: 正規ユーザーは 5 分で 2000 req（=6.7 req/秒）は超えない│
└─────────────────────────────────────────────────────────────────┘
     │ PASS
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Priority 50: BlockScannerUA (50 WCU)                            │
│  ──────────────────────────────────────────────────────────────  │
│  条件: User-Agent ヘッダーに "sqlmap" を含む（小文字変換後）       │
│  アクション: BLOCK                                                │
│  用途: sqlmap などの SQLi 自動スキャンツールをデフォルト UA で排除  │
│  補足: Nikto は NFW IPS (Suricata) でブロック（役割分担）         │
└─────────────────────────────────────────────────────────────────┘
     │ PASS
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Default Action: ALLOW                                            │
│  ──────────────────────────────────────────────────────────────  │
│  ★ ブラックリスト方式。どのルールにもマッチしないものは通す。     │
│     NFW がホワイトリスト（ドメイン許可リスト）を担い、            │
│     WAF がブラックリスト（既知の悪意あるパターン）を担う役割分担。 │
└─────────────────────────────────────────────────────────────────┘
```

#### WAF ログフィルタリング

```hcl
# BLOCK されたリクエストのみ CloudWatch Logs に保存（コスト最適化）
logging_filter {
  default_behavior = "DROP"  # 全リクエストを記録しない
  filter {
    behavior    = "KEEP"
    condition { action_condition { action = "BLOCK" } }
  }
}
```

---

## 6. トラフィックフロー詳細

### 攻撃リクエストがどのレイヤーでブロックされるか

#### ケース 1: SQL インジェクション `?id=1 UNION SELECT 1,2,3--`

```
攻撃者
  │  GET /?id=1+UNION+SELECT+1,2,3-- HTTP/1.1
  ▼
IGW → [IGW Edge RT] → NFW Endpoint
  │
  ├─ Stateless: PASS（ループバックではない）
  │
  ├─ Stateful ドメイン: HTTP_HOST をチェック → PASS（ALB の DNS は許可リスト外ではない）
  │   ※ ドメインフィルタリングは Host ヘッダーを見る。ALB の DNS はチェック対象外。
  │
  └─ Stateful IPS: "UNION" + "SELECT" にマッチ → DROP 🚫
       sid:1000002 SQL Injection UNION

もし NFW を通過した場合:
  ▼
ALB → WAF
  └─ Priority 20 CRS: SQLi_QUERYARGUMENTS にマッチ → BLOCK 403 🚫
```

#### ケース 2: 禁止ドメインへのアクセス（EC2 から）

```
EC2
  │  curl https://evil-site.test
  ▼
Public Subnet Route Table → NFW Endpoint
  │
  ├─ Stateless: PASS
  │
  └─ Stateful ドメイン: TLS SNI = "evil-site.test"
       ALLOWLIST に存在しない → DROP 🚫

EC2 の curl は接続タイムアウトになる
CloudWatch Logs (amf-nfw/alert) にブロックイベントが記録される
```

#### ケース 3: 正常なアクセス

```
ユーザー
  │  GET / HTTP/1.1  User-Agent: Mozilla/5.0
  ▼
IGW → NFW (全ルール PASS) → NACL (Port 80 許可) → ALB
  │
  └─ WAF 全ルール PASS → Default: ALLOW
       ▼
     ALB fixed-response: "amf-lab: OK" 200 ✅
```

#### ケース 4: スキャナー（sqlmap）による攻撃

```
攻撃者
  │  GET / HTTP/1.1  User-Agent: sqlmap/1.7
  ▼
IGW → NFW
  │
  └─ IPS: sid:1000001-1000004 にマッチしない（UA はここでは非検査）
     → PASS → ALB → WAF
       │
       └─ Priority 50 BlockScannerUA: "sqlmap" を含む → BLOCK 403 🚫
```

---

## 7. EC2 / SSM 設計

### EC2 仕様

| 項目 | 値 | 理由 |
|---|---|---|
| インスタンスタイプ | t4g.nano | arm64(Graviton3) でコスト最小化 |
| AMI | Amazon Linux 2023 (arm64) | SSM Agent 同梱、最新カーネル |
| サブネット | Private (10.0.10.0/24, 1a) | パブリック IP 不要 |
| IMDSv2 | 強制 (`http_tokens = "required"`) | SSRF によるメタデータ窃取防止 |
| EBS | gp3 / 8GB / 暗号化 | 最小スペック + セキュリティ |
| 公開 IP | なし | SSH も不要、SSM のみ |

### SSM Session Manager の動作原理

```
管理者 PC
  │  aws ssm start-session --target i-xxxx
  ▼
AWS Systems Manager サービス（インターネット経由）
  │
  ▼
VPC Interface Endpoint × 3 （Private Subnet 1a に配置）
  ├── com.amazonaws.ap-northeast-1.ssm
  ├── com.amazonaws.ap-northeast-1.ec2messages
  └── com.amazonaws.ap-northeast-1.ssmmessages

  ★ EC2 からこれらのエンドポイントへ outbound 443 を張り続ける
  ★ SSM Agent が起動していればセッションを受け付けられる状態になる

  ▼
EC2 の SSM Agent がトンネルを確立 → 管理者が操作可能
```

**NAT Gateway が不要な理由**
SSM の通信は VPC Endpoint 経由（PrivateLink）で完結するため、
Internet 経由の NAT Gateway が不要。NAT Gateway のコスト（$0.062/時間）を節約できる。

### IAM 権限設計

```
EC2 Instance Profile
  └── Role: amf-role-ec2-ssm
        └── Policy: AmazonSSMManagedInstanceCore (AWS マネージドポリシー)
              ├── ssm:UpdateInstanceInformation
              ├── ssmmessages:CreateControlChannel
              ├── ssmmessages:CreateDataChannel
              ├── ec2messages:GetMessages
              └── ... (SSM Agent 動作に必要な最小セット)
```

---

## 8. 可観測性（ログ設計）

### ログ一覧

| ログ種別 | CloudWatch Log Group | 用途 | 保持期間 |
|---|---|---|---|
| VPC Flow Logs | `/aws/vpc/flow-log/amf-vpc` | 全通信の IP/ポートレベル記録 | 7 日 |
| NFW アラート | `/aws/network-firewall/amf-nfw/alert` | NFW がブロック・許可したイベント | 30 日 |
| NFW フロー | `/aws/network-firewall/amf-nfw/flow` | 全 TCP セッションの開始・終了 | 7 日 |
| WAF ブロック | `aws-waf-logs-amf-alb` | WAF でブロックされたリクエスト | 7 日 |

> WAF ログ名は `aws-waf-logs-` プレフィックスが AWS の必須要件（これ以外は使用不可）。

### ログフィルタリング設計

```
VPC Flow Logs: traffic_type = "ALL"
  → ACCEPT も REJECT も記録。SG/NACL のブロックを Flow Logs で確認できる。
  → ACCEPT のみだと NACL での DENY が見えない。

NFW アラートログ: DROP したパケットのみ記録
  → フローログより小さいデータ量で重要なイベントを取得できる。

WAF ログ: BLOCK されたリクエストのみ記録
  → logging_filter で BLOCK のみ KEEP。全リクエストを記録するとコスト急増。
```

### CloudWatch Insights クエリ例

```sql
-- WAF ブロックの内訳（どのルールが多く発動しているか）
fields @timestamp, terminatingRuleId, httpRequest.uri, httpRequest.clientIp
| filter action = "BLOCK"
| stats count(*) by terminatingRuleId
| sort count desc
| limit 20

-- NFW でブロックされたドメイン一覧
fields @timestamp, event.tls.sni, event.dest_ip, event.src_ip
| filter event.action = "blocked"
| stats count(*) by event.tls.sni
| sort count desc
```

---

## 9. Terraform モジュール構成

### モジュール依存関係

```
environments/dev/main.tf
  │
  ├── module "vpc"               ← Phase 1: ネットワーク基盤
  │     outputs: vpc_id, subnet_ids, igw_id, route_table_ids
  │
  ├── module "security_group"    ← Phase 1: SG 定義
  │     depends_on: module.vpc (vpc_id)
  │     outputs: web_sg_id, app_sg_id, ssm_sg_id
  │
  ├── module "nacl"              ← Phase 1: NACL ルール
  │     depends_on: module.vpc (vpc_id, subnet_ids)
  │
  ├── module "network_firewall"  ← Phase 2: NFW + ルートテーブル書き換え
  │     depends_on: module.vpc (firewall_subnet_id, public_route_table_id)
  │     ★ vpc モジュールのルートテーブルを上書きする（0.0.0.0/0 の向き先を変更）
  │
  ├── module "alb"               ← Phase 3: ALB（WAF のアタッチ先）
  │     depends_on: module.vpc, module.security_group
  │     outputs: alb_arn, alb_dns_name
  │
  ├── module "waf"               ← Phase 3: WAF WebACL
  │     depends_on: module.alb (alb_arn)
  │
  └── module "ec2_ssm"           ← 検証用 EC2
        depends_on: module.vpc, module.security_group
```

### 各モジュールのリソース一覧

#### vpc モジュール
| リソース | 名前 |
|---|---|
| aws_vpc | amf-vpc |
| aws_subnet (public × 2) | amf-public-1a, amf-public-1c |
| aws_subnet (private × 2) | amf-private-1a, amf-private-1c |
| aws_subnet (firewall × 2) | amf-firewall-1a, amf-firewall-1c |
| aws_internet_gateway | amf-igw |
| aws_route_table (public) | amf-rtb-public |
| aws_route_table (private) | amf-rtb-private |
| aws_vpc_endpoint (ssm × 3) | amf-vpce-ssm, amf-vpce-ec2messages, amf-vpce-ssmmessages |
| aws_security_group (vpce) | amf-sg-vpce |
| aws_flow_log | amf-flow-log |
| aws_cloudwatch_log_group | /aws/vpc/flow-log/amf-vpc |
| aws_iam_role | amf-role-vpc-flow-log |

#### network_firewall モジュール
| リソース | 名前 |
|---|---|
| aws_networkfirewall_rule_group (stateless) | amf-nfw-stateless-rg |
| aws_networkfirewall_rule_group (domain) | amf-nfw-domain-rg |
| aws_networkfirewall_rule_group (ips) | amf-nfw-ips-rg |
| aws_networkfirewall_firewall_policy | amf-nfw-policy |
| aws_networkfirewall_firewall | amf-nfw |
| aws_networkfirewall_logging_configuration | (amf-nfw に対して設定) |
| aws_route_table (igw edge) | amf-rtb-igw-edge |
| aws_route_table (firewall) | amf-rtb-firewall |
| aws_route (igw→nfw × 2) | Public Subnet CIDR ごと |
| aws_route (public→nfw) | 0.0.0.0/0 → NFW Endpoint |
| aws_cloudwatch_log_group (alert) | /aws/network-firewall/amf-nfw/alert |
| aws_cloudwatch_log_group (flow) | /aws/network-firewall/amf-nfw/flow |

#### waf モジュール
| リソース | 名前 |
|---|---|
| aws_wafv2_ip_set | amf-waf-blocked-ips |
| aws_wafv2_web_acl | amf-waf-alb |
| aws_wafv2_web_acl_association | (alb_arn に対してアタッチ) |
| aws_cloudwatch_log_group | aws-waf-logs-amf-alb |
| aws_wafv2_web_acl_logging_configuration | (amf-waf-alb に対して設定) |

---

## 10. コスト設計

### リソース別コスト（東京リージョン、2024年時点）

| リソース | 課金単位 | 単価 | 月額（常時稼働） | 節約方法 |
|---|---|---|---|---|
| NFW Endpoint | $0.395/h/AZ × 1 | 時間 | ~$284 | 使用後即 destroy |
| NFW データ処理 | $0.065/GB | 通信量 | ~$1 | — |
| VPC Interface Endpoint × 3 | $0.014/h × 3 | 時間 | ~$30 | 使用後即 destroy |
| ALB | $0.008/h + LCU | 時間+通信 | ~$6 | 使用後即 destroy |
| EC2 t4g.nano | $0.0054/h | 時間 | ~$4 | Stop で節約 |
| CloudWatch Logs | $0.76/GB (ingestion) | データ量 | ~$1 | — |
| **合計（常時稼働）** | | | **~$326/月** | |
| **合計（4 時間使用）** | | | **~$2** | |

> ⚠️ CLAUDE.md の月額目標「$5〜$15」は**短期ハンズオン（数時間）**を前提とした値。
> 常時稼働すると Network Firewall と VPC Endpoint だけで $314/月になるため、
> **ハンズオン終了後は必ず `terraform destroy` を実行すること。**

### コスト最適化の設計判断

```
NAT Gateway を使わない理由:
  通常の設計では Private Subnet に NAT Gateway を置くが、
  本ハンズオンでは SSM の VPC Endpoint 経由でアクセスするため不要。
  NAT Gateway は $0.062/h = 月額 ~$45 かかるため、省略することでコストを削減。

NFW を 1AZ にする理由:
  本番なら全 AZ に NFW Endpoint が必要（AZ をまたいだルーティング不可）。
  1AZ 増やすごとに $284/月 追加されるため、ハンズオンでは 1AZ に限定。

t4g.nano (arm64) を使う理由:
  x86_64 の t3.nano ($0.0068/h) より Graviton の t4g.nano ($0.0054/h) の方が安く、
  かつ性能も高い。Amazon Linux 2023 は arm64 に最適化されている。
```

---

## 11. セキュリティ設計原則

本プロジェクトが実践する設計原則とその具体的な実装箇所。

### 最小権限原則（Least Privilege）

```
IAM:
  - EC2 は AmazonSSMManagedInstanceCore のみ（SSH キーペアなし）
  - VPC Flow Logs 用ロールは CloudWatch Logs への書き込みのみ

SG:
  - amf-sg-app: Web SG からの 8080 のみ受信（IP 範囲ではなく SG 参照）
  - amf-sg-vpce: VPC 内の 443 のみ（0.0.0.0/0 の inbound なし）

NFW:
  - ドメイン ALLOWLIST 方式: 許可するドメインだけを明示（デフォルト DROP）
```

### 多層防御（Defense in Depth）

```
Layer 1 (NACL):     サブネットレベルのフィルタ。SSH の明示的 DENY。
Layer 2 (SG):       インスタンスレベル。ステートフルで役割ベース制御。
Layer 3 (NFW):      VPC 境界の集中制御。ドメイン・IPS・プロトコル。
Layer 4 (WAF):      アプリ直前の精密検査。SQLi・XSS・Bot・Rate。

各レイヤーの補完関係:
  - SG で防げない「明示的 DENY」を NACL が担う
  - WAF が防げない「外部通信の制御」を NFW が担う
  - NFW が防げない「アプリ固有の攻撃」を WAF が担う
```

### ゼロトラスト

```
NFW ドメイン許可リスト:
  許可するドメインを明示的にリストアップし、それ以外はすべて DROP。
  「何でも通す」ではなく「必要なものだけ通す」。

NACL の SSH DENY:
  デフォルトは DENY だが、明示的に DENY ルールを書くことで
  意図が明確になり、設定ミスのリスクを下げる。
```

### 不変インフラ / コード化

```
全リソースを Terraform で管理:
  - 設定ドリフト（手動変更）が生じない
  - レビュー可能（terraform plan で差分確認）
  - 再現性がある（destroy → apply でクリーンに再構築）

設計理由コメント:
  全リソースに「# 設計理由:」コメントを付与し、
  WHY がコードに残るようにする。
```

### IMDSv2 強制

```hcl
metadata_options {
  http_tokens                 = "required"   # IMDSv1 を無効化
  http_put_response_hop_limit = 1            # コンテナからのアクセスを防止
}
```

SSRF 脆弱性（Server-Side Request Forgery）を利用して
`http://169.254.169.254/latest/meta-data/iam/...` から
IAM クレデンシャルを窃取する攻撃（CVE-2019 系）を防ぐ。

---

## 12. 本番化チェックリスト

ハンズオンから本番環境に移行する際に追加すべき要素。

### ネットワーク

- [ ] NFW Endpoint を全稼働 AZ に配置（1AZ → 全 AZ）
- [ ] NAT Gateway を各 AZ に配置（EC2 のアウトバウンドが必要な場合）
- [ ] Private Subnet の EC2 が外部 API を使う場合は NFW ドメイン許可リストに追加
- [ ] CloudFront を ALB の前段に配置（グローバルエッジでの DDoS 緩和）

### WAF

- [ ] WAF を CloudFront にもアタッチ（CLOUDFRONT スコープ、us-east-1 で作成）
- [ ] AWS Shield Advanced の有効化（$3,000/月〜、L3/L4 DDoS 保護）
- [ ] WAF Bot Control ルールの追加（高度なボット判定、追加料金あり）
- [ ] マネージドルールの COUNT → BLOCK への移行（誤検知確認後）
- [ ] IP レピュテーションリスト（AWSManagedRulesAmazonIpReputationList）の追加

### 可観測性

- [ ] CloudWatch Logs の保持期間を 90 日以上に延長（セキュリティ要件）
- [ ] CloudWatch Alarms の設定（NFW ブロック急増、WAF ブロック率異常）
- [ ] CloudTrail の有効化（API 操作ログ）
- [ ] AWS Security Hub の有効化（セキュリティスコアの一元管理）
- [ ] GuardDuty の有効化（異常検知）

### IAM / アクセス管理

- [ ] IAM Access Analyzer の有効化
- [ ] SCPs（Service Control Policies）で危険な操作を組織レベルで禁止
- [ ] MFA の強制

### コスト

- [ ] AWS Budgets でアラート設定
- [ ] Cost Anomaly Detection の有効化
- [ ] Reserved Instance / Savings Plans の検討（EC2）

### 運用

- [ ] Terraform Backend を S3 + DynamoDB（State Locking）に移行 ← 本プロジェクト済み
- [ ] Terraform Cloud / GitHub Actions での CI/CD 化
- [ ] `terraform plan` を PR レビューで自動実行
- [ ] WAF ルールのテスト自動化（attack_simulation.sh の CI 組み込み）
