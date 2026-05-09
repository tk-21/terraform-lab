# ARCHITECTURE.md
# Global Accelerator × Firehose × DataBrew Platform

## 目次

1. [プロジェクト概要](#1-プロジェクト概要)
2. [全体アーキテクチャ図](#2-全体アーキテクチャ図)
3. [データフロー詳細](#3-データフロー詳細)
4. [ネットワーク構成](#4-ネットワーク構成)
5. [各コンポーネント詳細](#5-各コンポーネント詳細)
6. [データスキーマ設計](#6-データスキーマ設計)
7. [IAM権限設計](#7-iam権限設計)
8. [Terraformモジュール構成](#8-terraformモジュール構成)
9. [S3バケット設計](#9-s3バケット設計)
10. [観測性（Observability）設計](#10-観測性observability設計)
11. [CI/CD設計](#11-cicd設計)
12. [セキュリティ設計](#12-セキュリティ設計)
13. [コスト設計](#13-コスト設計)

---

## 1. プロジェクト概要

AWS の以下の4サービスを組み合わせた、グローバルトラフィック制御 + リアルタイムデータ取り込み + ノーコードETL基盤のハンズオン。

| サービス | 役割 |
|---|---|
| **AWS Global Accelerator** | Anycast IPによるグローバルエントリーポイント。AWSバックボーンネットワーク経由でALBへルーティング |
| **Amazon Kinesis Data Firehose** | Lambda からの JSON ログをバッファリングして S3 に安定配信 |
| **AWS Glue DataBrew** | ノーコードETLでRaw NDJSONをParquetに変換・カラム付加 |
| **Amazon Athena** | S3上のParquetをSQLでインタラクティブ分析 |

**プロジェクト短縮名**: `gaf`（global-accelerator-firehose）  
**対象リージョン**: `ap-northeast-1`（東京）  
**Terraform バージョン**: >= 1.6 / AWS Provider >= 5.0

---

## 2. 全体アーキテクチャ図

```
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                        EventBridge Scheduler                            │
 │                        （rate: 3分おき）                                │
 └──────────────────────────────┬──────────────────────────────────────────┘
                                │ Lambda:InvokeFunction
                                ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Lambda Generator  [gaf-dev-generator]                               │
 │  Python 3.12 / arm64 / 128MB / timeout:120s                         │
 │  VPC: private subnet                                                 │
 │                                                                      │
 │  ・50リクエストをループ送信（0.1秒間隔）                             │
 │  ・Method: GET×6, POST×3, DELETE×1 からランダム選択                 │
 │  ・Path: /api/users | /api/products | /api/orders | /health          │
 │  ・UserAgent: ブラウザ / curl / python-requests からランダム         │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ HTTPS（NAT Gateway経由）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  AWS Global Accelerator  [gaf-dev-accelerator]                       │
 │                                                                      │
 │  静的 Anycast IP × 2（全世界共通エントリーポイント）                 │
 │  Listener: TCP 80 / TCP 443                                          │
 │  Flow Logs → S3 (gaf-raw/global-accelerator-flow-logs/)             │
 │                                                                      │
 │  ┌─────────────────────────────────────────────┐                    │
 │  │  Endpoint Group (ap-northeast-1)            │                    │
 │  │  HealthCheck: HTTP /health  (30秒間隔 ×3)  │                    │
 │  │  Traffic Dial: 100%                         │                    │
 │  │  Client IP Preservation: Enabled            │                    │
 │  └─────────────────────────────────────────────┘                    │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ AWSバックボーンネットワーク
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Application Load Balancer  [gaf-dev-alb]                            │
 │  External / ap-northeast-1a, 1c の Public Subnet                    │
 │                                                                      │
 │  Listener :80  HTTP → forward（開発時）or 301 Redirect to 443       │
 │  Listener :443 HTTPS → forward（ACM証明書設定時）                   │
 │                                                                      │
 │  Target Group: gaf-dev-receiver-tg  (type=lambda)                   │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ Lambda:InvokeFunction
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Lambda Receiver  [gaf-dev-receiver]                                 │
 │  Python 3.12 / arm64 / 256MB / timeout:30s                          │
 │  VPC: private subnet                                                 │
 │                                                                      │
 │  受け取るHTTPリクエストを解析してJSONログレコードを組み立て：         │
 │  ・X-Forwarded-For から source_ip / accelerator_ip を抽出           │
 │  ・X-Amz-Cf-Id の prefix から edge_location を判定                  │
 │  ・source_ip の末尾オクテット mod 4 で source_region を疑似推定      │
 │  ・latency_ms = 関数開始から Firehose PUT 前までの経過時間           │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ Firehose:PutRecord（NDJSON + \n）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Kinesis Data Firehose  [gaf-dev-delivery-stream]                    │
 │  destination: extended_s3                                            │
 │  SSE: AWS_OWNED_CMK                                                  │
 │                                                                      │
 │  バッファ設定                                                         │
 │  ├── buffering_interval: 60秒                                        │
 │  └── buffering_size:    5MB                                          │
 │  （どちらか先に達したら S3 に書き込み）                              │
 │                                                                      │
 │  書き込みパス:                                                        │
 │  ├── 正常: logs/year=YYYY/month=MM/day=DD/hour=HH/                  │
 │  └── エラー: errors/year=YYYY/month=MM/<error-type>/                │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ S3:PutObject（NDJSON）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  S3 Raw Bucket  [gaf-dev-raw-{account_id}]                           │
 │  SSE: AES256（SSE-S3）  Versioning: Enabled                         │
 │  Lifecycle: 60日→IA, 180日→削除                                     │
 │                                                                      │
 │  logs/year=2026/month=05/day=06/hour=12/                            │
 │  └── firehose-1-2026-05-06-12-00-00-xxxx.json  （NDJSON形式）       │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ S3:GetObject（1時間おき）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  AWS Glue DataBrew Job  [gaf-dev-job]                                │
 │  type: RECIPE / max_capacity: 5 DPU / schedule: cron(0 * * * ? *)   │
 │                                                                      │
 │  Recipe [gaf-dev-recipe] の変換ステップ:                             │
 │  1. CAST status_code → INTEGER                                       │
 │  2. CAST latency_ms  → INTEGER                                       │
 │  3. DELETE_ROWS_WITH_NULL_IN_COLUMN (request_id)                     │
 │  4. CREATE_COLUMN latency_category                                   │
 │     if(latency_ms < 100, "fast",                                     │
 │        if(latency_ms < 500, "normal", "slow"))                       │
 │  5. CREATE_COLUMN is_error                                           │
 │     if(status_code >= 400, true, false)                              │
 │  6. CREATE_COLUMN processed_at = now()                               │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ S3:PutObject（Parquet + Snappy）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  S3 Processed Bucket  [gaf-dev-processed-{account_id}]               │
 │  SSE: AES256  Versioning: Enabled                                    │
 │  Lifecycle: 90日→IA, 365日→削除                                     │
 │                                                                      │
 │  processed/part-00000.snappy.parquet                                 │
 └───────────────────────────┬──────────────────────────────────────────┘
                             │ Glue Data Catalog（メタデータ参照）
                             ▼
 ┌──────────────────────────────────────────────────────────────────────┐
 │  Amazon Athena  [gaf-dev-workgroup]                                  │
 │  Engine: Athena engine version 3                                     │
 │  スキャン上限: 1GB/クエリ                                             │
 │  結果保存: gaf-dev-athena-results-{account_id}  (7日で自動削除)      │
 │                                                                      │
 │  -- Athena クエリ例 --                                               │
 │  SELECT latency_category, count(*) as cnt                           │
 │  FROM gaf_dev_db.processed_logs                                      │
 │  GROUP BY latency_category;                                          │
 └──────────────────────────────────────────────────────────────────────┘
```

---

## 3. データフロー詳細

### 3.1 リクエスト生成フロー

```
EventBridge Scheduler
│  schedule: rate(3 minutes)
│  target: Lambda Generator
│  input: {}
│
└─► Lambda Generator 起動
    │
    ├─► ループ50回 (0.1秒間隔)
    │   ├── method  = random.choice([GET×6, POST×3, DELETE×1])
    │   ├── path    = random.choice([/api/users, /api/products,
    │   │                            /api/orders, /health])
    │   ├── ua      = random.choice([browser, curl, python-requests])
    │   └── X-Simulated-Region ヘッダ付与（ダミーリージョン情報）
    │
    └─► HTTPS POST → Global Accelerator DNS名
        (NAT Gateway → Internet → GA Anycast IP)
```

### 3.2 ログ受信・Firehose送信フロー

```
ALB → Lambda Receiver 呼び出し（ALB Integration Event形式）
│
├── event.headers["x-forwarded-for"] を解析
│   形式: "client_ip, ga_ip"
│   └── ips[0] = source_ip（クライアントIP）
│       ips[-1] = accelerator_ip（GAのIP）
│
├── source_ip の最終オクテット mod 4 でリージョン疑似判定
│   0 → us-east-1 / 1 → eu-west-1 / 2 → ap-northeast-1 / 3 → ap-southeast-1
│
├── X-Amz-Cf-Id の先頭3文字でエッジロケーション判定
│   nrt → NRT / iad → IAD / dub → DUB / sin → SIN
│
├── latency_ms = 関数開始 ～ firehose.put_record() 呼び出し直前の経過時間
│
└── Firehose.PutRecord({
        DeliveryStreamName: FIREHOSE_STREAM_NAME,
        Record: { Data: json.dumps(log_record) + "\n" }  ← NDJSON区切り
    })
```

### 3.3 Firehose バッファリング → S3 書き込みフロー

```
Firehose受信バッファ
│
├── 条件A: 蓄積量が 5MB を超えた
├── 条件B: 最後の書き込みから 60秒 経過
│   （どちらか先に達したらS3フラッシュ）
│
└─► S3 書き込み
    ├── 正常パス: s3://gaf-raw/logs/year=YYYY/month=MM/day=DD/hour=HH/
    │           firehose-1-YYYY-MM-DD-HH-mm-ss-{uuid}  (UNCOMPRESSED NDJSON)
    │
    └── エラーパス: s3://gaf-raw/errors/year=YYYY/month=MM/<error-type>/
                   （処理失敗レコードを別保存することで再処理可能）
```

### 3.4 DataBrew ETL フロー

```
DataBrew Schedule: cron(0 * * * ? *)  ← 毎時0分に起動
│
└─► DataBrew Job: gaf-dev-job (RECIPE type)
    │
    ├── Input Dataset: s3://gaf-raw/logs/  (NDJSON, multi_line=false)
    │
    ├── Recipe Step 1: CAST status_code → INTEGER
    ├── Recipe Step 2: CAST latency_ms  → INTEGER
    ├── Recipe Step 3: 削除 (request_id が null の行)
    ├── Recipe Step 4: 追加カラム latency_category
    │   fast   ← latency_ms < 100ms
    │   normal ← 100ms ≤ latency_ms < 500ms
    │   slow   ← latency_ms ≥ 500ms
    ├── Recipe Step 5: 追加カラム is_error
    │   true  ← status_code ≥ 400
    │   false ← status_code < 400
    └── Recipe Step 6: 追加カラム processed_at = now()
        │
        └─► Output: s3://gaf-processed/processed/
                    format: PARQUET + SNAPPY
                    row_count: 1,000,000 rows/file
                    overwrite: true
```

---

## 4. ネットワーク構成

```
 VPC: 10.0.0.0/16  [gaf-dev-vpc]
 │
 ├── Public Subnet 1  10.0.1.0/24  ap-northeast-1a
 │   ├── ALB (ENI)
 │   └── NAT Gateway  [gaf-dev-nat]
 │       └── EIP  [gaf-dev-nat-eip]
 │
 ├── Public Subnet 2  10.0.2.0/24  ap-northeast-1c
 │   └── ALB (ENI)
 │
 ├── Private Subnet 1  10.0.11.0/24  ap-northeast-1a
 │   ├── Lambda Receiver (ENI) ← ALB TargetGroup
 │   └── Lambda Generator (ENI)
 │
 └── Private Subnet 2  10.0.12.0/24  ap-northeast-1c
     ├── Lambda Receiver (ENI)
     └── Lambda Generator (ENI)
 │
 ├── Internet Gateway  [gaf-dev-igw]
 │   └── Public Route Table: 0.0.0.0/0 → IGW
 │
 └── Private Route Table: 0.0.0.0/0 → NAT Gateway
     （Lambdaの外部通信：Firehose API, Global Accelerator）
```

### セキュリティグループ構成

```
 [SG: gaf-dev-alb-sg]
 Inbound:
   TCP 443 from 0.0.0.0/0   ← Global AcceleratorはAWSネットワーク経由でも
   TCP 80  from 0.0.0.0/0      パブリックIPからALBに到達するため全開が必要
 Outbound:
   All → 0.0.0.0/0

 [SG: gaf-dev-lambda-receiver-sg]
 Inbound:
   TCP 443 from gaf-dev-alb-sg  ← ALBからのみ許可（SG参照）
 Outbound:
   TCP 443 → 0.0.0.0/0          ← Firehose API / CloudWatch

 [SG: gaf-dev-lambda-generator-sg]
 Inbound:
   なし（インバウンド不要）
 Outbound:
   TCP 443 → 0.0.0.0/0          ← Global AcceleratorへのHTTPS
```

---

## 5. 各コンポーネント詳細

### 5.1 Lambda Generator

| 項目 | 値 |
|---|---|
| 関数名 | `gaf-dev-generator` |
| ランタイム | Python 3.12 / arm64 |
| メモリ | 128 MB |
| タイムアウト | 120秒 |
| 配置 | VPC プライベートサブネット |
| トリガー | EventBridge Scheduler（3分おき） |
| 環境変数 | `ACCELERATOR_ENDPOINT` = `https://<ga-dns-name>` |

**動作**: 1回の呼び出しで50リクエストを0.1秒間隔で連続送信し、集計結果（success/failure/平均レイテンシ）をCloudWatch Logsに出力して終了。

### 5.2 AWS Global Accelerator

| 項目 | 値 |
|---|---|
| リソース名 | `gaf-dev-accelerator` |
| IP種別 | IPV4（Anycast IP × 2） |
| リスナー | TCP 80 / TCP 443 |
| Client Affinity | NONE（ステートレス設計） |
| ヘルスチェック | HTTP `/health` 30秒間隔 閾値3回 |
| フローログ | S3 `gaf-raw/global-accelerator-flow-logs/` |

**なぜ Global Accelerator を使うか**:  
通常のALB直アクセスはパブリックインターネットを経由するが、Global Acceleratorを挟むことでエッジポイントからAWSバックボーンネットワークに乗り換え、レイテンシが安定する。また静的Anycast IPにより、DNSフェイルオーバー待ち不要でエンドポイント切り替えが可能。

### 5.3 Application Load Balancer

| 項目 | 値 |
|---|---|
| リソース名 | `gaf-dev-alb` |
| タイプ | external（インターネット向け） |
| サブネット | Public Subnet × 2（AZ冗長） |
| ターゲット | Lambda Receiver（type=lambda） |
| HTTPS | `use_https=true` かつ ACM 証明書ARN指定時に有効 |

**Lambda ターゲットグループの注意点**:  
Lambda がターゲットの場合、ALBはHTTPリクエストをJSON形式（ALB Integration Event）に変換してLambdaを同期呼び出しする。レスポンスもJSON形式（`statusCode`, `headers`, `body`）で返す必要がある。

### 5.4 Lambda Receiver

| 項目 | 値 |
|---|---|
| 関数名 | `gaf-dev-receiver` |
| ランタイム | Python 3.12 / arm64 |
| メモリ | 256 MB（Firehose SDK呼び出し分を考慮） |
| タイムアウト | 30秒 |
| 配置 | VPC プライベートサブネット |
| トリガー | ALB（ターゲットグループ経由） |
| 環境変数 | `FIREHOSE_STREAM_NAME` = `gaf-dev-delivery-stream` |

**aws-lambda-powertools の利用**:  
`@logger.inject_lambda_context` デコレータにより、Lambda Context情報（requestId等）が自動的にログに含まれる。構造化ログとして CloudWatch Logs Insights でクエリしやすい形式。

### 5.5 Kinesis Data Firehose

| 項目 | 値 |
|---|---|
| ストリーム名 | `gaf-dev-delivery-stream` |
| 送信先 | extended_s3 |
| バッファ間隔 | 60秒 |
| バッファサイズ | 5 MB |
| 圧縮 | UNCOMPRESSED（DataBrewが処理しやすいJSON形式を維持） |
| 暗号化 | AWS_OWNED_CMK（SSE有効） |
| エラー出力 | `errors/` プレフィックスに別保存 |

**なぜ Lambda から直接 S3 に書かないか**:  
高頻度の `PutObject` は S3 のスロットリングリスクがある。Firehose がバッファリングすることでファイル数を削減し、小ファイル問題（多数の数KBファイルが生まれるAnti-pattern）を回避。またFirehoseはリトライと失敗レコードの分離保存を自動で行う。

### 5.6 S3 バケット（3本構成）

| バケット | 用途 | データ形式 |
|---|---|---|
| `gaf-dev-raw-{account}` | Firehoseの書き込み先 / GA フローログ | NDJSON |
| `gaf-dev-processed-{account}` | DataBrew の出力先 | Parquet + Snappy |
| `gaf-dev-athena-results-{account}` | Athenaクエリ結果の一時保存 | CSV / JSON |

### 5.7 AWS Glue DataBrew

DataBrew はGUIベースでETLレシピを定義できるノーコードETLサービス。Terraformで `aws_databrew_recipe` リソースを定義することで、GUIで作ったのと同等のレシピをコードとして管理できる。

| コンポーネント | 名前 |
|---|---|
| Dataset | `gaf-dev-raw-dataset` |
| Recipe | `gaf-dev-recipe` |
| Project | `gaf-dev-databrew-project` |
| Job | `gaf-dev-job` |
| Schedule | `gaf-dev-schedule`（毎時0分） |

### 5.8 Glue Data Catalog + Athena

Glue Data Catalog は S3 上のデータに対してスキーマを定義するメタデータストア。Athena はこのカタログを参照してS3のデータをSQLで直接クエリする。

| テーブル | データソース | パーティション |
|---|---|---|
| `raw_logs` | S3 Raw バケット / NDJSON | year / month / day / hour |
| `processed_logs` | S3 Processed バケット / Parquet | なし |

---

## 6. データスキーマ設計

### 6.1 Raw ログ（NDJSON形式）

Firehoseが S3 に書き込む1行1レコードのJSONフォーマット。

```json
{
  "request_id":    "550e8400-e29b-41d4-a716-446655440000",
  "timestamp":     "2026-05-06T12:34:56.789000",
  "source_ip":     "203.0.113.42",
  "source_region": "us-east-1",
  "method":        "GET",
  "path":          "/api/orders",
  "status_code":   200,
  "latency_ms":    87,
  "user_agent":    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
  "accelerator_ip":"75.2.100.12",
  "edge_location": "NRT"
}
```

| カラム | 型 | 説明 |
|---|---|---|
| request_id | string | UUID v4 |
| timestamp | string | ISO8601形式 UTC |
| source_ip | string | X-Forwarded-Forの最初のIP |
| source_region | string | IPオクテット mod4 から疑似推定 |
| method | string | HTTPメソッド |
| path | string | URLパス |
| status_code | int | HTTPステータスコード |
| latency_ms | int | Lambda処理時間(ms) |
| user_agent | string | User-Agentヘッダ |
| accelerator_ip | string | X-Forwarded-Forの最後のIP（GA IP） |
| edge_location | string | X-Amz-Cf-Id先頭3文字から判定 |

### 6.2 Processed ログ（Parquet + Snappy）

DataBrew変換後のスキーマ。Raw の全カラムに加え以下が付加される。

| 追加カラム | 型 | 値 |
|---|---|---|
| latency_category | string | `fast`(<100ms) / `normal`(100-499ms) / `slow`(≥500ms) |
| is_error | boolean | `true` if status_code ≥ 400 |
| processed_at | timestamp | DataBrew実行時刻 |

### 6.3 スキーマ変換図

```
S3 Raw (NDJSON)                     S3 Processed (Parquet)
─────────────────                   ─────────────────────────────────
request_id    string      ────────► request_id    string
timestamp     string      ────────► timestamp     string
source_ip     string      ────────► source_ip     string
source_region string      ────────► source_region string
method        string      ────────► method        string
path          string      ────────► path          string
status_code   string(raw) ──CAST──► status_code   int
latency_ms    string(raw) ──CAST──► latency_ms    int
user_agent    string      ────────► user_agent    string
accelerator_ip string     ────────► accelerator_ip string
edge_location string      ────────► edge_location string
                                    latency_category string  ◄── NEW
                                    is_error         boolean ◄── NEW
                                    processed_at     timestamp◄── NEW
```

---

## 7. IAM権限設計

最小権限の原則（PoLP）に基づき、ロールごとに必要最小限の権限のみを付与。

```
 gaf-dev-firehose-role
 ├── Assume: firehose.amazonaws.com
 ├── s3:PutObject, s3:GetObject, s3:ListBucket → raw バケット
 └── logs:PutLogEvents, CreateLogGroup, CreateLogStream → *

 gaf-dev-receiver-role
 ├── Assume: lambda.amazonaws.com
 ├── firehose:PutRecord, PutRecordBatch → delivery-stream ARN のみ
 ├── logs:* → CloudWatch Logs
 └── ec2:CreateNetworkInterface, Describe, Delete → VPC Lambda必須

 gaf-dev-generator-role
 ├── Assume: lambda.amazonaws.com
 ├── AWSリソース操作権限 なし（外部HTTPリクエストのみ）
 ├── logs:* → CloudWatch Logs
 └── ec2:CreateNetworkInterface, Describe, Delete → VPC Lambda必須

 gaf-dev-databrew-role
 ├── Assume: databrew.amazonaws.com
 ├── AWSGlueDataBrewServiceRole（マネージドポリシー）
 ├── s3:GetObject, ListBucket → raw バケット（読み取り専用）
 ├── s3:PutObject, DeleteObject, ListBucket → processed バケット
 └── glue:GetDatabase, GetTable, CreateTable, UpdateTable, GetPartitions → *

 gaf-dev-scheduler-role
 ├── Assume: scheduler.amazonaws.com
 └── lambda:InvokeFunction → generator Lambda ARN のみ

 gaf-dev-github-actions-role
 ├── Assume: WebIdentity (GitHub Actions OIDC)
 │   Condition: repo:takuya/global-accelerator-firehose-databrew-platform:*
 ├── ec2/s3/lambda/iam/logs の読み取り系 → *（plan用）
 └── s3:GetObject, PutObject, DeleteObject → state バケット のみ
```

**設計上の重要ポイント**:
- Receiver は Firehose ARN 直指定で S3 直書き込み禁止
- Generator は AWS サービス操作権限ゼロ（外部HTTP送信専用）
- GitHub Actions はアクセスキー不使用（OIDC一時クレデンシャル）
- DataBrew は Raw 読み取り専用 / Processed 書き込み専用で分離

---

## 8. Terraformモジュール構成

### 8.1 モジュール依存関係

```
main.tf
│
├── module.networking
│   └── 出力: vpc_id, public_subnet_ids, private_subnet_ids,
│             sg_alb_id, sg_lambda_receiver_id, sg_lambda_generator_id
│
├── module.s3
│   └── 出力: raw_bucket_arn, raw_bucket_id,
│             processed_bucket_arn, processed_bucket_id,
│             athena_results_bucket_id
│
├── module.iam ─────────────── depends on: s3（バケットARN）
│   └── 出力: firehose_role_arn, lambda_receiver_role_arn,
│             lambda_generator_role_arn, databrew_role_arn,
│             scheduler_role_arn, github_actions_role_arn
│
├── module.firehose ─────────── depends on: iam, s3
│   └── 出力: delivery_stream_name, delivery_stream_arn
│
├── module.lambda_receiver ──── depends on: iam, firehose, networking, alb
│   └── 出力: function_arn, function_name
│   ※ alb との循環依存に注意:
│     lambda_receiver は alb_target_group_arn を受け取るが
│     alb は lambda_receiver_arn を受け取る
│     → alb モジュールが先にTGを作り、receiver への permission は
│       receiver モジュール内で count条件つきで後付け
│
├── module.alb ─────────────── depends on: networking, lambda_receiver
│   └── 出力: alb_arn, alb_arn_suffix, alb_dns_name, target_group_arn
│
├── module.global_accelerator ── depends on: alb, s3（フローログ先）
│   └── 出力: accelerator_dns_name, accelerator_ip_sets, accelerator_arn
│
├── module.lambda_generator ──── depends on: iam, networking, global_accelerator
│   └── 出力: function_name
│   ※ Generator の ACCELERATOR_ENDPOINT は GA の DNS 名から構築
│
├── module.databrew ──────────── depends on: s3, iam
│   └── 出力: job_name, project_name
│
├── module.glue ─────────────── depends on: s3
│   └── 出力: database_name, athena_workgroup_name
│
└── module.observability ─────── depends on: alb, lambda_receiver,
                                             lambda_generator, firehose
    └── 出力: dashboard_name
```

### 8.2 Terraform Backend 設定

```hcl
backend "s3" {
  bucket = "REPLACE_WITH_YOUR_STATE_BUCKET"  # -backend-config で上書き
  key    = "gaf/terraform.tfstate"
  region = "ap-northeast-1"
}
```

初期化コマンド:
```bash
terraform init \
  -backend-config="bucket=<your-state-bucket>" \
  -backend-config="key=gaf/terraform.tfstate" \
  -backend-config="region=ap-northeast-1"
```

### 8.3 locals.tf の命名規則

```hcl
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  # デフォルト: "gaf-dev"
}
```

全リソースは `${local.name_prefix}-<suffix>` の形式で命名される。

---

## 9. S3バケット設計

### 9.1 バケット一覧とライフサイクル

```
gaf-dev-raw-{account_id}
├── 用途: Firehose書き込み先 / GA フローログ
├── SSE: AES256（SSE-S3）
├── Versioning: 有効
├── Public Access: 完全ブロック
└── Lifecycle
    ├── 0日  → STANDARD（新規書き込み）
    ├── 60日 → STANDARD_IA（アクセス頻度低下を考慮）
    └── 180日 → 削除

gaf-dev-processed-{account_id}
├── 用途: DataBrew 出力先（Parquet）
├── SSE: AES256（SSE-S3）
├── Versioning: 有効
├── Public Access: 完全ブロック
└── Lifecycle
    ├── 0日  → STANDARD
    ├── 90日 → STANDARD_IA
    └── 365日 → 削除

gaf-dev-athena-results-{account_id}
├── 用途: Athena クエリ結果一時保存
├── SSE: AES256（SSE-S3）
├── Versioning: なし（一時ファイルのため不要）
├── Public Access: 完全ブロック
└── Lifecycle
    └── 7日 → 削除（クエリ結果は短期間で不要）
```

### 9.2 S3 パス設計

```
gaf-dev-raw-{account}/
├── logs/
│   └── year=2026/month=05/day=06/hour=12/
│       └── gaf-dev-delivery-stream-1-2026-05-06-12-00-00-{uuid}
│           （Hive形式パーティション → Athena raw_logs テーブルで参照可能）
├── errors/
│   └── year=2026/month=05/<error-type>/
│       └── 配信失敗レコード（再処理用）
└── global-accelerator-flow-logs/
    └── AWSLogs/{account-id}/globalaccelerator/...

gaf-dev-processed-{account}/
└── processed/
    └── part-00000.snappy.parquet
        （DataBrew が overwrite:true で毎回上書き）
```

---

## 10. 観測性（Observability）設計

### 10.1 CloudWatch Dashboard 構成

```
gaf-dev-dashboard
│
├── セクション1: Global Accelerator & ALB
│   ├── GA: NewFlowCount / ProcessedByteCount（us-east-1 ※GA指定）
│   └── ALB: RequestCount / 5xx数(赤) / TargetResponseTime-p99
│
├── セクション2: Lambda & Kinesis Firehose
│   ├── Lambda Receiver: Invocations / Errors(赤) / Duration-p99
│   ├── Lambda Generator: Invocations / Errors(赤)
│   └── Firehose: IncomingRecords / DeliveryToS3.Records / DataFreshness-Max
│
└── セクション3: DataBrew & Data Lake
    └── DataBrew Job実行履歴（CloudWatch Logs Insightsクエリ）
        ※ DataBrewはCloudWatch Metricsを出さないためLogs Insightsで代替
```

**Global Accelerator のメトリクスは `us-east-1` で取得する**点に注意。GAはグローバルサービスのため、メトリクスは常に `us-east-1` リージョンに記録される。

### 10.2 CloudWatch Alarms

| アラーム名 | 条件 | 閾値 |
|---|---|---|
| `gaf-dev-firehose-delivery-error` | S3配信成功数が0 | 3回連続（15分間） |
| `gaf-dev-alb-5xx-spike` | ALB 5xxエラー数 ≥ 10 | 2回連続（2分間） |

### 10.3 CloudWatch Logs

| ロググループ | 保存期間 |
|---|---|
| `/aws/lambda/gaf-dev-receiver` | 7日 |
| `/aws/lambda/gaf-dev-generator` | 7日 |
| `/aws/kinesisfirehose/gaf-dev-delivery-stream` | 7日 |

---

## 11. CI/CD設計

### 11.1 GitHub Actions ワークフロー

```
.github/workflows/terraform.yml

トリガー:
├── push to main    → terraform-ci ジョブのみ実行
└── pull_request    → terraform-ci + terraform-plan 両方実行

terraform-ci ジョブ（常時）:
├── OIDC で AWS 認証（アクセスキー不使用）
├── terraform fmt -check -recursive
├── terraform init -backend=false
└── terraform validate

terraform-plan ジョブ（PR時のみ）:
├── OIDC で AWS 認証
├── terraform init（S3バックエンド指定）
├── terraform plan
│   -var="aws_account_id=${{ secrets.AWS_ACCOUNT_ID }}"
│   -var="backend_bucket=${{ secrets.TF_STATE_BUCKET }}"
└── Plan結果をPRコメントに自動投稿（60KB超は末尾切り捨て）
```

### 11.2 必要な GitHub Secrets

| Secret名 | 内容 |
|---|---|
| `AWS_ROLE_ARN` | `gaf-dev-github-actions-role` の ARN |
| `AWS_ACCOUNT_ID` | AWSアカウントID |
| `TF_STATE_BUCKET` | Terraform stateを保存するS3バケット名 |

### 11.3 OIDC認証フロー

```
GitHub Actions Runner
│
├── OIDC Token 発行（GitHubが署名）
│   subject: repo:takuya/global-accelerator-firehose-databrew-platform:ref:refs/heads/main
│
└─► AWS STS AssumeRoleWithWebIdentity
    │  RoleARN: gaf-dev-github-actions-role
    │  Condition:
    │    aud = "sts.amazonaws.com"
    │    sub like "repo:takuya/global-accelerator-firehose-databrew-platform:*"
    │
    └─► 一時クレデンシャル発行（有効期間1時間）
        アクセスキーをSecretに保存不要
```

---

## 12. セキュリティ設計

### 12.1 禁止パターンと実装

| 禁止パターン | 対策 |
|---|---|
| S3パブリックアクセス | 全バケットで `block_public_acls/policy/ignore/restrict = true` |
| Lambdaへのアクセスキーハードコード | IAMロール + 環境変数（ARNのみ渡す） |
| Firehoseの暗号化なし | `server_side_encryption { enabled = true, key_type = AWS_OWNED_CMK }` |
| ALBへの不要ポート開放 | SG: `80`, `443` のみ inbound 許可 |
| DataBrewへのAdmin権限 | AWSGlueDataBrewServiceRole + 最小カスタムポリシー |
| CI/CDアクセスキー保管 | GitHub Actions OIDC（一時クレデンシャル） |

### 12.2 ネットワークセキュリティ

- Lambda（Receiver/Generator）はプライベートサブネットに配置
- Receiver は ALB SG からのみ inbound 許可（0.0.0.0/0 は不可）
- Generator は inbound なし・outbound HTTPS(443)のみ
- NAT Gateway 経由で外部通信（パブリックIP を Lambda が直接持たない）

### 12.3 データセキュリティ

- 全 S3 バケット: SSE-S3 (AES256) 暗号化
- Firehose: AWS_OWNED_CMK による保存時暗号化
- Athena 結果: SSE_S3 暗号化 + クエリスキャン上限 1GB / クエリ

---

## 13. コスト設計

### 13.1 月額概算

| サービス | 概算 | 備考 |
|---|---|---|
| Global Accelerator | ~$18 | $0.025/時 固定 + $0.01/GB データ転送 |
| ALB | ~$16 | 最低料金 $0.0225/時 |
| Lambda（Receiver） | < $1 | 50req × 20回/時 × 30日 = 730,000呼び出し |
| Lambda（Generator） | < $1 | 20回/時 × 30日 = 14,400呼び出し |
| Kinesis Firehose | < $1 | $0.029/GB、データ量は微量 |
| Glue DataBrew | < $1 | 1回/時 × 0.5DPU × $1/DPU時 × 30日 |
| S3 | < $1 | ストレージ + リクエスト料金 |
| CloudWatch | < $1 | メトリクス・ログ・ダッシュボード |
| **合計** | **~$36/月** | |

> **注意**: Global Accelerator と ALB が固定コストとして高い。ハンズオン後は速やかに `terraform destroy` を実行すること（~$34/月の削減）。

### 13.2 コスト最適化ポイント

- NAT Gateway をシングルAZ構成（本番では各AZに配置するが、コスト優先）
- Lambda メモリを必要最小限に設定（Generator: 128MB、Receiver: 256MB）
- S3 ライフサイクルポリシーで長期保存コストを自動削減
- DataBrew スケジュールを毎時1回に制限（より頻繁にすると DPU コスト増）
