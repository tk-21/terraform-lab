# ARCHITECTURE.md — waf-cloudfront-security-lab 完全理解ドキュメント

## 1. このプロジェクトが作るもの

AWS WAF v2 + CloudFront + Lambda@Edge + Shield Advanced による **多層 Web セキュリティ基盤**。
攻撃を「エッジ → WAF → アプリ前段」の 3 層で防ぎ、ログを Athena で分析、Chatwork へリアルタイム通知する。

```
攻撃者
  │  SQLi / XSS / DDoS / スキャン
  ▼
[Layer 1] CloudFront エッジ ─── DDoS 軽減・キャッシュ・HTTPS 終端
  │
  ▼
[Layer 2] WAF WebACL ────────── マネージドルール + カスタムルール + レートリミット
  │
  ▼
[Layer 3] Lambda@Edge ──────── X-CloudFront-Secret ヘッダー検証（ALB 直アク防止）
  │
  ▼
[Layer 4] ALB ──────────────── SG でリクエスト制御・HTTPS 終端
  │
  ▼
[Layer 5] ECS Fargate ──────── プライベートサブネット・VPC Endpoint 経由のみ

      ↓ 非同期ログパイプライン
WAF ログ → Kinesis Firehose → S3 → Athena

      ↓ アラート通知パイプライン
CloudWatch Alarm → EventBridge → Lambda → Chatwork
```

---

## 2. ディレクトリ構造と役割

```
waf-cloudfront-security-lab/
│
├── terraform/                   ← Terraform ルート設定
│   ├── main.tf                  ← モジュール呼び出し・依存関係の定義
│   ├── variables.tf             ← 入力変数 (project, env, domain_name 等)
│   ├── outputs.tf               ← 全モジュールの出力値を集約
│   ├── versions.tf              ← Provider バージョン制約
│   ├── backend.tf               ← S3 + DynamoDB による tfstate 管理
│   └── modules/
│       ├── origin/              ← VPC・ALB・ECS Fargate（オリジン基盤）
│       ├── waf/                 ← WAF WebACL・ルール・Regex Pattern Set
│       ├── cloudfront/          ← CloudFront ディストリビューション・Lambda@Edge
│       ├── waf-logs/            ← Kinesis Firehose・S3・Athena（ログ分析基盤）
│       └── alert/               ← CloudWatch Alarm・EventBridge・Lambda（通知）
│
├── lambda/
│   ├── edge/
│   │   └── viewer_request.js    ← Lambda@Edge: X-CloudFront-Secret ヘッダー検証
│   └── alert_notifier/
│       └── main.py              ← WAF ブロック多発 → Chatwork 通知
│
├── athena/queries/              ← WAF ログ分析 SQL クエリ集
├── scripts/
│   ├── test_waf.sh              ← WAF 動作検証（PASS/FAIL 出力）
│   └── simulate_attack.sh      ← Athena 確認用 攻撃パターン一括送信
└── docs/
    ├── architecture.md          ← Mermaid 図（簡易版）
    ├── waf-rule-design.md       ← WAF ルール設計思想（自己記述）
    └── adr/                     ← Architecture Decision Records 4 本
```

---

## 3. リージョン戦略（重要）

このプロジェクトは **2 リージョンを使い分ける**。混乱しやすいため最初に整理する。

```
us-east-1（バージニア）          ap-northeast-1（東京）
─────────────────────────────    ────────────────────────────
WAF WebACL (CLOUDFRONT スコープ)  VPC / サブネット
Kinesis Firehose (WAF ログ)       ALB
CloudFront ディストリビューション  ECS Fargate
Lambda@Edge (viewer_request)      ECS タスク実行ロール
ACM 証明書 (CloudFront 用)        ACM 証明書 (ALB 用)
CloudWatch Alarm (WAF メトリクス) SSM Parameter Store (Chatwork Token)
EventBridge                       CloudWatch Logs (ECS)
Lambda alert_notifier
SSM Parameter Store (CF Secret)
```

**なぜ us-east-1 にこれだけ多くあるのか？**
- CloudFront のバックエンドは us-east-1 に存在する。
- `CLOUDFRONT` スコープの WAF は **us-east-1 でしか作れない**（AWS 仕様）。
- WAF メトリクスも us-east-1 にしか存在しない → Alarm・EventBridge・Lambda も us-east-1。
- Lambda@Edge は us-east-1 で作成・publish したものを CloudFront がエッジへ自動レプリケート。

**Terraform での実現方法（provider alias）**

```hcl
# versions.tf
provider "aws" {
  region = "ap-northeast-1"   # デフォルト
}
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

# main.tf でモジュール呼び出し時にプロバイダーを指定
module "waf" {
  source    = "./modules/waf"
  providers = { aws = aws.use1 }   # us-east-1 で作成
}
```

---

## 4. モジュール詳解

### 4-1. module/origin — オリジン基盤

**作成するリソース一覧**

| リソース | 設定値 | ポイント |
|---|---|---|
| VPC | 10.0.0.0/16 | NAT Gateway なし |
| パブリックサブネット | 1a/1c 各 /24 | ALB のみ配置 |
| プライベートサブネット | 1a/1c 各 /24 | ECS Fargate タスク配置 |
| IGW | - | ALB のインターネット通信用 |
| VPC Endpoint (ecr-api) | Interface 型 | docker pull マニフェスト取得 |
| VPC Endpoint (ecr-dkr) | Interface 型 | docker pull レイヤーダウンロード |
| VPC Endpoint (s3) | **Gateway 型（無料）** | ECR レイヤーの実体は S3 に格納 |
| VPC Endpoint (logs) | Interface 型 | ECS → CloudWatch Logs |
| VPC Endpoint (ssm) | Interface 型 | ECS → SSM Parameter Store |
| ALB | Internet-facing / HTTPS:443 | TLS 1.3 対応ポリシー |
| ACM 証明書（ALB 用） | ap-northeast-1 | origin.{domain} を保護 |
| ACM 証明書（CF 用） | **us-east-1** | CloudFront は us-east-1 の証明書のみ対応 |
| ECS クラスター | - | FARGATE_SPOT 主体 |
| ECS タスク定義 | arm64 / Graviton2 | nginx:alpine |
| ECS タスク実行ロール | 最小権限 | ECR Pull + CW Logs + SSM |
| CloudWatch Logs | /ecs/wcsl-dev-origin | 保持 30 日 |

**ネットワーク設計図**

```
Internet
   │
   ▼ (0.0.0.0/0 → IGW)
┌─────────────────────────────────────────────────────┐
│ VPC 10.0.0.0/16                                     │
│                                                     │
│  パブリックサブネット (10.0.0.x / 10.0.1.x)          │
│  ┌─────────────────────────────────────────────┐    │
│  │  ALB (sg-alb: 0.0.0.0/0:443 許可)           │    │
│  └─────────────────────────────────────────────┘    │
│                  │                                  │
│  プライベートサブネット (10.0.10.x / 10.0.11.x)      │
│  ┌─────────────────────────────────────────────┐    │
│  │  ECS Fargate (sg-ecs: ALB SG からのみ許可)   │    │
│  │                                             │    │
│  │  ← VPC Endpoint 経由で以下へアクセス →      │    │
│  │    ECR API / ECR DKR / S3                   │    │
│  │    CloudWatch Logs / SSM                    │    │
│  └─────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────┘
```

**NAT Gateway を使わない理由**

プライベートサブネットの ECS タスクが必要とする外部通信（ECR/S3/CloudWatch Logs/SSM）は
すべて VPC Endpoint で代替できる。NAT Gateway は月額約 $32〜 かかるため、
VPC Endpoint（Interface 型）に切り替えることでコストを削減しつつプライベートネットワーク性も向上する。

---

### 4-2. module/waf — WAF WebACL

**ルール優先度と動作モード**

```
Priority 1:  RateLimitPerIP          → BLOCK (最初から block: 独自ルールのため誤検知リスクなし)
Priority 2:  BlockAdminPaths         → BLOCK (独自 Regex: /admin /wp-admin /.env 等)
Priority 3:  BlockMaliciousUserAgents→ BLOCK (独自 Regex: sqlmap nikto nessus 等)
Priority 10: AWSManagedRulesCommonRuleSet      → COUNT (OWASP Top 10 基本セット)
Priority 20: AWSManagedRulesKnownBadInputsRuleSet → COUNT (Log4Shell / Spring4Shell 等)
Priority 30: AWSManagedRulesSQLiRuleSet        → BLOCK (SQLi: 誤検知確認済みのため block)
Priority 40: AWSManagedRulesAmazonIpReputationList → BLOCK (悪意ある IP リスト)
```

**count / block の使い分け原則**

```
カスタムルール → 最初から block
  理由: 自分で書いたルールなので意図通り動くかどうかを把握している

マネージドルール → count から始め、ログで誤検知確認後に block へ昇格
  理由: AWS がルールを更新するため、自分のアプリで False Positive が
        発生するかどうかを実トラフィックで確認してから block にする
```

**Regex Pattern Set の具体的なパターン**

管理パスブロック (`admin_paths`):
```
^/admin       ^/wp-admin     ^/phpmyadmin
^\.env$       ^/config
```

不正 UA ブロック (`malicious_ua`):
```
sqlmap   nikto   nessus   masscan   zgrab
```

**WebACL の全体設定**
- スコープ: `CLOUDFRONT`（us-east-1 に作成）
- デフォルトアクション: `allow`（明示ブロック以外は通す）
- 全ルールで `cloudwatch_metrics_enabled = true`（攻撃メトリクスを CloudWatch に記録）

---

### 4-3. module/cloudfront — CloudFront + Lambda@Edge

**CloudFront の役割**

1. **エッジキャッシュ**: 静的コンテンツをエッジで返却し ALB 負荷を削減
2. **WAF アタッチ**: `web_acl_id` で WAF WebACL を紐付け
3. **HTTPS 終端**: TLSv1.2_2021 以上を強制
4. **カスタムヘッダー付与**: ALB へ転送するとき `X-CloudFront-Secret` を付与

**Lambda@Edge（viewer_request）の動作**

```
ユーザーリクエスト到着
        ↓
Lambda@Edge (viewer-request) が起動
        ↓
request.headers['x-cloudfront-secret'] を検証
        ├─ ヘッダーなし or 値が不一致 → { status: '403', body: 'Access Denied' }
        └─ 値が一致 → return request（そのままオリジンへ転送）
```

**Lambda@Edge の制約と設定値**

| 制約事項 | 設定値 | 理由 |
|---|---|---|
| リージョン | us-east-1 のみ作成可能 | CloudFront の要件 |
| アーキテクチャ | **x86_64（arm64 不可）** | Lambda@Edge は arm64 非対応 |
| タイムアウト上限 | 5 秒（viewer-request） | 設定値: 5 |
| メモリ上限 | 128 MB（viewer-request） | 設定値: 128 |
| 環境変数 | **使用不可** | Lambda@Edge の制約 |
| publish = true | 必須 | CloudFront は qualified ARN を要求 |

**環境変数が使えない問題の解決策**

Lambda@Edge は環境変数を使えないため、`__REPLACE_AT_DEPLOY__` プレースホルダーを
`local_file` リソースがデプロイ時に SSM の値で置換して `.build/viewer_request.js` を生成する。

```hcl
resource "local_file" "viewer_request_embedded" {
  content = replace(
    file("${path.module}/../../../lambda/edge/viewer_request.js"),
    "__REPLACE_AT_DEPLOY__",      # JS ファイル内のプレースホルダー
    var.cloudfront_secret          # SSM から取得した実際のシークレット値
  )
  filename = "${path.module}/.build/viewer_request.js"
}
```

**CloudFront の設定ポイント**

```
PriceClass_100    : 北米・欧州・アジアのエッジを使用（全世界より安価）
default_ttl = 0   : ALB への動的リクエストはキャッシュしない
min_ttl     = 0
max_ttl     = 0
転送ヘッダー: Host / Authorization / CloudFront-Viewer-Country
```

---

### 4-4. module/waf-logs — ログ分析基盤

**パイプライン全体像**

```
WAF WebACL
   │ aws_wafv2_web_acl_logging_configuration
   │ (ALLOW リクエストは DROP してコスト削減)
   ▼
Kinesis Firehose
  ・名前は "aws-waf-logs-" プレフィックスが必須（AWS 仕様）
  ・バッファ: 5 MB or 300 秒（どちらか早い方）
  ・圧縮: GZIP（ストレージコスト削減）
  ・パーティションプレフィックス:
    waf-logs/year=YYYY/month=MM/day=DD/
   │
   ▼
S3 バケット (wcsl-dev-waf-logs-{account_id})
  ・SSE-S3 暗号化 (AES256)
  ・パブリックアクセス全ブロック
  ・バージョニング有効
  ・ライフサイクル: 90日→Glacier / 365日→削除
   │
   ▼
Athena
  ・データベース: wcsl_dev_waf
  ・ワークグループ: wcsl-dev-waf
  ・クエリスキャン上限: 1 GB（コスト暴走防止）
  ・テーブルスキーマは Named Query として保存済み
  ・クエリ結果は athena-results バケットに保存
```

**Athena テーブルスキーマのポイント**

WAF ログは JSON 形式で出力される。`httpRequest` が入れ子構造になっており、
クライアント IP・国・URI・HTTP メソッドを個別に取り出せる。

```sql
-- 攻撃元 IP ランキング（athena/queries/top_blocked_ips.sql）
SELECT
  httpRequest.clientIp AS client_ip,
  httpRequest.country  AS country,
  COUNT(*)             AS blocked_count
FROM waf_logs
WHERE action = 'BLOCK'
  AND year = '2025' AND month = '01'   -- パーティションフィルタ必須
GROUP BY 1, 2
ORDER BY blocked_count DESC
LIMIT 20;
```

**なぜ CloudWatch Logs に直接送らないのか**

WAF v2 のログ出力先は Kinesis Firehose・S3・CloudWatch Logs の 3 択だが、
CloudWatch Logs への送信はロール設定が複雑な上にストレージコストが高い。
Firehose 経由で S3 + Athena とする構成が AWS 推奨かつコスト最小。

---

### 4-5. module/alert — 攻撃検知通知パイプライン

**通知フロー**

```
[us-east-1]
CloudWatch Metric Alarm
  ・メトリクス: AWS/WAFV2 の BlockedRequests
  ・集計: Sum / 5 分間
  ・しきい値: > 100 リクエスト（var.waf_block_threshold）
  ・dimensions に Region = "us-east-1" が必須（CLOUDFRONT スコープの WAF のため）
  ・alarm_actions は不要（EventBridge がデフォルトバスで自動受信）
        ↓ 状態が OK → ALARM に遷移したとき
EventBridge Rule
  ・イベントソース: aws.cloudwatch
  ・フィルタ: alarmName = "wcsl-dev-waf-block-high" かつ state.value = "ALARM"
        ↓
Lambda (alert_notifier)
  ・ランタイム: Python 3.12 / arm64 / 128 MB / タイムアウト 30 秒
  ・Lambda Powertools: 構造化ログ・X-Ray トレーシング
  ・SSM Parameter Store (ap-northeast-1) からクロスリージョンで Chatwork Token 取得
        ↓
Chatwork REST API
  ・POST /v2/rooms/{room_id}/messages
  ・メッセージ: アラーム名・状態・理由・リージョン・コンソール URL
```

**クロスリージョン SSM の理由**

Lambda は us-east-1 で動作するが、Chatwork Token を格納した SSM は ap-northeast-1 にある。
Lambda コード内で明示的に `boto3.client("ssm", region_name="ap-northeast-1")` を呼び出すことで
クロスリージョンアクセスを実現している。IAM ポリシーも ap-northeast-1 の ARN に絞り込み済み。

**Lambda Powertools の活用**

```python
logger = Logger()    # 構造化 JSON ログ (CloudWatch Logs Insights で検索可能)
tracer = Tracer()    # X-Ray トレーシング（SSM 取得・Chatwork API 呼び出しをトレース）

@tracer.capture_lambda_handler
@logger.inject_lambda_context
def handler(event, context):
    ...
```

---

## 5. セキュリティ設計の詳細

### 5-1. ALB 直接アクセス防止の仕組み

CloudFront をバイパスして ALB に直接 HTTP リクエストを送るケースを防ぐための設計。

```
① CloudFront が ALB へリクエストを転送するとき:
     X-CloudFront-Secret: <ランダム文字列> を付与

② Lambda@Edge (viewer-request) がリクエストを受信時:
     x-cloudfront-secret ヘッダーの値を検証
     → 値が一致しない場合は 403 を即座に返す

③ ALB セキュリティグループ（Phase 2 以降）:
     CloudFront マネージドプレフィックスリストのみ許可
```

**X-CloudFront-Secret の管理**

```
SSM Parameter Store (us-east-1)
  /wcsl/dev/cloudfront-secret = <ランダム文字列>
      ↓
Terraform が SSM から値を取得
      ↓
CloudFront custom_header に設定（ALB への送信時に付与）
Lambda@Edge のソースコードに埋め込み（デプロイ時に replace）
```

### 5-2. IAM 最小権限設計

**ECS タスク実行ロール**

```
ECS タスク実行ロールに許可するアクション:
  ecr:GetDownloadUrlForLayer    ─ ECR レイヤー取得
  ecr:BatchGetImage             ─ ECR イメージ取得
  ecr:BatchCheckLayerAvailability ─ ECR レイヤー存在確認
  ecr:GetAuthorizationToken     ─ docker login（resource = * が AWS 仕様上必須）
  logs:CreateLogStream          ─ CW Logs ストリーム作成
  logs:PutLogEvents             ─ CW Logs ログ送信
  ssm:GetParameter              ─ SSM パラメータ取得（/wcsl/dev/* のみ）
```

**alert_notifier Lambda 実行ロール**

```
許可するアクション:
  ssm:GetParameter  ─ /wcsl/dev/chatwork-token のみ (1 リソース限定)
  xray:PutTraceSegments 等  ─ X-Ray（マネージドポリシー経由）
  logs:*  ─ CloudWatch Logs（マネージドポリシー経由）
```

**Firehose 実行ロール**

```
許可するアクション:
  s3:AbortMultipartUpload / GetBucketLocation / GetObject
  s3:ListBucket / ListBucketMultipartUploads / PutObject
  対象: waf-logs バケット + バケット内オブジェクト（ARN で限定）
```

### 5-3. シークレット管理

ハードコードは一切行わない。すべて SSM Parameter Store 経由。

| シークレット | 格納先 | 利用者 |
|---|---|---|
| X-CloudFront-Secret | SSM (us-east-1) `/wcsl/dev/cloudfront-secret` | CloudFront + Lambda@Edge |
| Chatwork API Token | SSM (ap-northeast-1) `/wcsl/dev/chatwork-token` | alert_notifier Lambda |

---

## 6. コスト設計

### 6-1. アーキテクチャレベルのコスト最適化

| 最適化手法 | 節約額目安 | 代替/理由 |
|---|---|---|
| NAT Gateway 不使用 | ~$32/月 | VPC Endpoint（Gateway 型は無料）で代替 |
| ECS arm64 (Graviton2) | x86_64 比 ~20% 削減 | architectures = ["arm64"] |
| FARGATE_SPOT | オンデマンド比 ~70% 削減 | 割り込み許容の場合 |
| CloudFront PriceClass_100 | PriceClass_All より ~30% 削減 | 全世界配信不要 |
| Firehose GZIP 圧縮 | S3 コスト ~70% 削減 | compression_format = "GZIP" |
| Athena スキャン量上限 | コスト暴走防止 | bytes_scanned_cutoff = 1 GB |
| S3 ライフサイクル | 長期コスト削減 | 90日→Glacier / 365日→削除 |
| Shield Advanced | $3,000/月 → Phase 4 のみ | 動作確認後即削除 |

### 6-2. 月額コスト試算

| サービス | 概算 | 主な内訳 |
|---|---|---|
| ALB | ~$20 | 固定費 ($0.0243/時) |
| CloudFront | ~$5 | PriceClass_100 + 低トラフィック |
| WAF | ~$10 | WebACL $5 + ルール $3 + リクエスト数 |
| ECS Fargate | ~$5 | arm64 + FARGATE_SPOT + 小サイズ |
| VPC Endpoint (Interface 型 4 本) | ~$15 | $0.01/時 × 4 × 2AZ |
| Kinesis Firehose | ~$1 | 従量（低トラフィック） |
| S3 (WAF ログ) | ~$1 | GZIP 圧縮後 + Glacier 移行 |
| Lambda | $0 | 無料枠内 |
| **合計（Shield 除く）** | **~$57** | |

---

## 7. デプロイ依存関係

```
module.origin ─────────────────────────────┐
  ├─ VPC / サブネット                        │
  ├─ ECS クラスター                          │
  ├─ ALB ─────────────────────────────────  │
  ├─ ACM 証明書 (ap-northeast-1 + us-east-1)│
  └─ alb_dns_name, acm_certificate_arn_use1 を出力

module.waf ────────────────────────────────│
  └─ webacl_arn, webacl_name を出力         │

module.waf_logs ────────────────────────── │
  ├─ depends on: module.waf (webacl_arn)   │
  └─ Kinesis Firehose + S3 + Athena        │

data.aws_ssm_parameter.cloudfront_secret ──│
  └─ SSM から X-CloudFront-Secret を取得   │

module.cloudfront ──────────────────────── │
  ├─ depends on: module.origin (alb_dns_name, acm_certificate_arn_use1)
  ├─ depends on: module.waf (webacl_arn)
  ├─ depends on: cloudfront_secret (SSM)
  └─ cloudfront_domain_name, cloudfront_distribution_id を出力

module.alert ───────────────────────────────
  └─ depends on: module.waf (webacl_name)
```

---

## 8. クリーンアップ時の注意点

Lambda@Edge を含む CloudFront の削除には特別な手順が必要。

```bash
# 1. CloudFront を先に destroy
#    Lambda@Edge のエッジレプリカ削除が始まる
terraform destroy -target=module.cloudfront

# 2. コンソールで CloudFront の Status が "Disabled" になるまで待つ（数分〜数十分）

# 3. 残りのリソースを削除
terraform destroy

# 4. 削除確認
aws wafv2 list-web-acls --scope CLOUDFRONT --region us-east-1
aws cloudfront list-distributions
aws s3 ls | grep wcsl
```

**なぜ CloudFront を先に削除するのか**

Lambda@Edge は CloudFront にアタッチされている間はレプリカが全エッジに存在する。
CloudFront を先に Disabled → Delete することでレプリカ削除が開始される。
CloudFront を残したまま Lambda@Edge を削除しようとするとエラーになる。

---

## 9. 動作検証コマンド集

```bash
# デプロイ後に出力値を確認
cd terraform
terraform output cloudfront_domain_name
terraform output athena_workgroup_name

# WAF 動作検証（全テスト PASS = 正常）
./scripts/test_waf.sh <CF_DOMAIN> [ALB_DNS]

# 攻撃シミュレーション → Athena でログ確認
./scripts/simulate_attack.sh <CF_DOMAIN>

# Athena: 攻撃元 IP ランキング
# コンソールで wcsl-dev-waf ワークグループを選択後、
# athena/queries/top_blocked_ips.sql を実行

# CloudWatch: WAF ブロック数の確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/WAFV2 \
  --metric-name BlockedRequests \
  --dimensions Name=Rule,Value=ALL Name=WebACL,Value=wcsl-dev-webacl Name=Region,Value=us-east-1 \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Sum \
  --region us-east-1
```

---

## 10. よくある疑問

**Q: WAF は CloudFront の前？後？**

WAF は CloudFront にアタッチされており、CloudFront がリクエストを受け取った直後・オリジンへ転送する前に評価される。ブロックされたリクエストはエッジで 403 を返すため、ALB や ECS には一切到達しない。

**Q: Lambda@Edge と CloudFront Functions はどう違うのか？**

CloudFront Functions は超軽量（メモリ 2 MB・実行 1 ms 以内）だが JavaScript 実行のみ。Lambda@Edge は Node.js/Python が使え、タイムアウトが長く外部 API 呼び出しも可能（ただし Lambda@Edge では外部 HTTP 呼び出しはタイムアウトリスクがあるため非推奨）。このプロジェクトでは SSM 値の埋め込みロジックが必要なため Lambda@Edge を採用。

**Q: Shield Advanced を使わないと何が困るのか？**

Shield Standard（デフォルト・無料）でも L3/L4 レベルの DDoS は防御される。Advanced を追加することで得られるのは:（1）L7 DDoS 自動緩和（2）DDoS で増加した AWS コストの払い戻し保証（3）AWS DDoS Response Team のサポート。月額 $3,000 のため、大規模 DDoS リスクのあるサービス以外では Standard + WAF で十分。

**Q: なぜ Kinesis Firehose の命名に `aws-waf-logs-` プレフィックスが必要なのか？**

AWS 仕様。WAF がログを配信する Firehose ストリームには必ず `aws-waf-logs-` で始まる名前をつけなければならない。これは `aws_wafv2_web_acl_logging_configuration` リソースが内部的にこのプレフィックスでストリームを探すため。
