# CLAUDE.md — waf-cloudfront-security-lab

## プロジェクト概要

AWS WAF v2 + CloudFront + Shield Advanced + Lambda@Edge による
**エンタープライズ級 Web セキュリティ基盤**のハンズオン。

「守る」設計をコードで表現し、WAF ルール設計の意図・Shield の保護範囲・
CloudFront の多層防御を面接で 15 分説明できる状態を目指す。

### ポートフォリオ的な差別化ポイント
- WAF マネージドルール + カスタムルール + レートリミットを全て Terraform で管理
- CloudFront ディストリビューション → ALB → ECS Fargate の多層構成
- Shield Advanced の自動 DDoS 緩和 + CloudWatch アラーム連動
- WAF ログを Kinesis Firehose → S3 → Athena でクエリ可能な分析基盤
- Lambda@Edge による地理制限・カスタムヘッダー付与
- Chatwork への攻撃検知通知パイプライン

---

## ディレクトリ構造

```
waf-cloudfront-security-lab/
├── CLAUDE.md
├── README.md
├── docs/
│   ├── architecture.md          # Mermaid アーキテクチャ図
│   ├── waf-rule-design.md       # WAF ルール設計思想（自分で記述）
│   └── adr/
│       ├── 001-waf-scope-cloudfront.md
│       ├── 002-managed-vs-custom-rules.md
│       ├── 003-shield-advanced-trade-off.md
│       └── 004-kinesis-firehose-for-waf-logs.md
├── terraform/
│   ├── backend.tf
│   ├── versions.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── main.tf
│   └── modules/
│       ├── waf/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── cloudfront/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── shield/
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── waf-logs/
│       │   ├── main.tf          # Kinesis Firehose + S3 + Athena
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── origin/
│       │   ├── main.tf          # ALB + ECS Fargate（オリジンサーバ）
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── alert/
│           ├── main.tf          # CloudWatch → EventBridge → Lambda → Chatwork
│           ├── variables.tf
│           └── outputs.tf
├── lambda/
│   ├── edge/
│   │   ├── viewer_request.js    # Lambda@Edge: カスタムヘッダー検証
│   │   └── origin_request.js   # Lambda@Edge: 地理制限補完
│   └── alert_notifier/
│       ├── main.py              # WAF アラーム → Chatwork 通知
│       └── requirements.txt
├── athena/
│   └── queries/
│       ├── top_blocked_ips.sql
│       ├── rule_match_summary.sql
│       └── country_breakdown.sql
├── scripts/
│   ├── test_waf.sh              # curl でルール動作確認
│   └── simulate_attack.sh      # SQLi/XSS テストリクエスト送信
└── runbook/
    ├── deploy.md
    ├── waf-rule-update.md
    └── incident-response.md
```

---

## 技術スタック・制約

### 必須制約（全フェーズ共通）
| 項目 | 設定値 | 理由 |
|------|--------|------|
| リージョン | `ap-northeast-1` | 標準 |
| WAF スコープ | `CLOUDFRONT` | グローバル配信前提 |
| Lambda@Edge リージョン | `us-east-1` | CloudFront 必須要件 |
| Terraform | `>= 1.9` | |
| Python Lambda | `3.12 / arm64` | Graviton2 コスト最適化 |
| Lambda Powertools | 必須 | 構造化ログ・トレーシング |
| IAM | 最小権限・ワイルドカード禁止 | |
| シークレット | SSM Parameter Store のみ | ハードコード禁止 |
| 通知先 | Chatwork REST API | |
| NAT Gateway | **禁止** | VPC Endpoint で代替 |
| アーキテクチャ | `arm64 / Graviton2` | |

### WAF 設計方針
- **スコープ**: `CLOUDFRONT`（us-east-1 に WAF WebACL を作成）
- **マネージドルール優先**: AWS マネージドルールを基本とし、カスタムルールで補完
- **レートリミット**: IP ベース 2000 req/5min をデフォルト
- **ログ全量保存**: Kinesis Firehose 経由で S3 に全リクエストログを保存
- **メトリクス**: 全ルールに CloudWatch メトリクス有効化

### コスト設計
- Shield Advanced: **フェーズ 4 のみ有効化**（月額 $3,000 のため動作確認後即削除）
- CloudFront: PriceClass_100（北米・欧州・アジア）
- Kinesis Firehose: 従量課金（低トラフィックのためほぼ無料）
- Athena: クエリごと課金（S3 Select で最小化）

### 命名規則
```
プロジェクトプレフィックス: wcsl（waf-cloudfront-security-lab）
リソース命名: wcsl-{env}-{resource}
例: wcsl-prod-waf-webacl, wcsl-prod-cf-distribution
IAM ロール上限: 64 文字厳守
```

### 禁止事項
- `aws_wafv2_web_acl` の `action = "block"` を全体に適用（テスト不能になる）
- WAF ルールへのハードコード IP アドレス
- Lambda@Edge での外部 HTTP 呼び出し（タイムアウトリスク）
- NAT Gateway の使用
- IAM ポリシーの `*` ワイルドカード
- Chatwork Token のコードへの直接記述

---

## フェーズ構成

| Phase | テーマ | 主要リソース |
|-------|--------|-------------|
| 1 | 基盤構築（VPC・ECS オリジン・ALB） | VPC, ECS Fargate, ALB, ACM, Route53 |
| 2 | CloudFront + WAF WebACL 基本構成 | CloudFront, WAF v2, マネージドルール |
| 3 | WAF カスタムルール + ログ分析基盤 | カスタムルール, Kinesis Firehose, S3, Athena |
| 4 | Lambda@Edge + 攻撃検知通知 | Lambda@Edge, CloudWatch Alarm, Chatwork 通知 |
| 5 | 動作検証・攻撃シミュレーション・ADR 完成 | テストスクリプト, 口頭説明チェック |

---

## ADR 記述ルール（重要）

ADR の本文は **必ず自分の言葉で記述すること**。
AI 生成テキストをそのまま貼ることを禁止する。

各 ADR に含める項目：
1. Context（なぜこの決定が必要だったか）
2. Decision（何を選んだか）
3. Alternatives（他に何を検討したか・なぜ却下したか）
4. Consequences（この決定のトレードオフ）

---

## 口頭説明チェックポイント

各フェーズ完了後、以下を自分の言葉で 15 分説明できるか確認すること：

- WAF の `CLOUDFRONT` スコープと `REGIONAL` スコープの違い
- マネージドルールの仕組みと誤検知（False Positive）対応方法
- CloudFront のオリジン設定と Signed URL の使い分け
- Shield Advanced が提供する保護とコストのトレードオフ
- Kinesis Firehose を選んだ理由（CloudWatch Logs との違い）
- Lambda@Edge の制約（メモリ・タイムアウト・リージョン）