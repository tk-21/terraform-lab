# IoT Stream Pipeline — アーキテクチャ完全理解ドキュメント

## 目次

1. [システム全体像](#1-システム全体像)
2. [データフロー詳細](#2-データフロー詳細)
3. [コンポーネント解説](#3-コンポーネント解説)
4. [IAM設計](#4-iam設計)
5. [コスト設計](#5-コスト設計)
6. [エラーハンドリング設計](#6-エラーハンドリング設計)
7. [ディレクトリ構成と責務](#7-ディレクトリ構成と責務)
8. [フェーズ別構築順序](#8-フェーズ別構築順序)
9. [面接トーキングポイント](#9-面接トーキングポイント)

---

## 1. システム全体像

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IoT Stream Pipeline                          │
│                                                                     │
│  ┌──────────────┐     ┌─────────────────┐     ┌─────────────────┐  │
│  │   センサー    │     │    Kinesis      │     │    Lambda       │  │
│  │ シミュレータ  │────▶│  Data Streams   │────▶│  (processor)   │  │
│  │  (Python)    │PUT  │  ON_DEMAND mode │ ESM │  arm64 / ECR   │  │
│  │  5デバイス   │     │  24h retention  │     │  batch=100     │  │
│  └──────────────┘     └─────────────────┘     └────────┬────────┘  │
│                                                         │PutItem    │
│  ┌──────────────┐     ┌─────────────────┐     ┌────────▼────────┐  │
│  │   クライアント│     │  API Gateway    │     │    DynamoDB     │  │
│  │  (curl/      │◀────│  REST API       │◀────│  PAY_PER_REQUEST│  │
│  │   browser)   │ GET │  /sensors/      │Query│  device_id (PK) │  │
│  └──────────────┘     │  {device_id}    │     │  timestamp (SK) │  │
│                        └────────┬────────┘     │  TTL: 72h      │  │
│                                 │Invoke        └─────────────────┘  │
│                        ┌────────▼────────┐                          │
│                        │    Lambda       │     ┌─────────────────┐  │
│                        │   (reader)      │     │      ECR        │  │
│                        │  arm64 / ECR   │     │  processor repo │  │
│                        └─────────────────┘     │  reader repo    │  │
│                                                │  (lifecycle: 1) │  │
│                                                └─────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

### 一言で言うと

> IoTセンサーが送ったデータを **Kinesis でバッファリング** し、
> **Lambda コンテナ** がリアルタイムに DynamoDB へ書き込む。
> **API Gateway + Lambda** で外部からデバイス別の最新データを取得できる。

---

## 2. データフロー詳細

### 書き込みパス（センサー → DynamoDB）

```
[センサーシミュレータ]
  ↓ kinesis.put_record(StreamName, Data, PartitionKey=device_id)
  ↓ PartitionKey=device_id → 同一デバイスのデータは同一シャードへ
  ↓ データはbase64エンコードされてKinesisに格納される

[Kinesis Data Streams]
  ↓ ESM (Event Source Mapping) がポーリング
  ↓ batch_size=100 件 または 10秒 のどちらか早い方でバッチ化
  ↓ Lambdaに {"Records": [...]} としてイベント送信
  ↓ 各Recordの data フィールドはbase64エンコード済み

[Lambda: processor]
  ↓ base64.b64decode(record["kinesis"]["data"])  ← デコード必須
  ↓ JSONパース → sensor_data dict
  ↓ temperature, humidity を Decimal型に変換（boto3要件）
  ↓ expires_at = now() + 72h  ← TTL自動削除用
  ↓ table.put_item(Item={device_id, timestamp, ...})

[DynamoDB]
  → iot-pipeline-table に永続化
  → 72時間後に expires_at TTLで自動削除
```

### 読み取りパス（API → DynamoDB）

```
[クライアント]
  ↓ GET https://{api-id}.execute-api.ap-northeast-1.amazonaws.com/v1/sensors/{device_id}
  ↓ クエリパラメータ: ?limit=10 (省略時デフォルト10)

[API Gateway REST API]
  ↓ Lambda Proxy統合 (type=AWS_PROXY)
  ↓ pathParameters, queryStringParameters をそのままLambdaに渡す
  ↓ マッピングテンプレート不要

[Lambda: reader]
  ↓ event["pathParameters"]["device_id"] を取得
  ↓ DynamoDB Query:
  │   KeyConditionExpression = device_id = :device_id
  │   ScanIndexForward = False  ← 最新データ優先
  │   Limit = limit
  ↓ Decimal → float 変換 (JSONシリアライズのため)
  ↓ {"statusCode": 200, "body": json.dumps({...})}

[API Gateway]
  → Lambdaレスポンスをそのままクライアントへ返す
```

### シーケンス図

```
センサー      Kinesis     Lambda(proc)   DynamoDB   API GW   Lambda(reader)
  │             │              │              │          │           │
  │─put_record─▶│              │              │          │           │
  │             │              │              │          │           │
  │             │──batch(100)─▶│              │          │           │
  │             │              │─put_item────▶│          │           │
  │             │              │◀─────────────│          │           │
  │             │◀─success─────│              │          │           │
  │             │              │              │          │           │
  │             │              │              │◀─GET─────│           │
  │             │              │              │          │──invoke──▶│
  │             │              │              │◀─query───────────────│
  │             │              │              │──items──────────────▶│
  │             │              │              │          │◀─response─│
  │             │              │              │◀─200─────│           │
```

---

## 3. コンポーネント解説

### 3-1. センサーシミュレータ (`simulator/sensor_simulator.py`)

| 設定項目 | 値 | 理由 |
|---|---|---|
| デバイス数 | 5台 | ThreadPoolExecutorで並列実行 |
| 送信間隔 | 2秒 | Kinesisコストを抑えつつ動作確認できる頻度 |
| 異常値混入率 | 5% | エラーハンドリングの動作検証用 |
| 実行時間 | 120秒 | E2Eテストを走らせるのに十分な時間 |

```python
# PartitionKeyをdevice_idにする意味
# → 同一デバイスのレコードが必ず同一シャードへ
# → シャード内では順序が保証される（デバイス単位の順序整合性）
kinesis.put_record(
    StreamName=STREAM_NAME,
    Data=json.dumps(data).encode("utf-8"),
    PartitionKey=device_id,   ← これがシャード決定のハッシュキー
)
```

**異常値の設計意図:**
```
通常データ: temperature=20〜35℃, status="normal"
異常データ: temperature=80〜100℃, status="critical"
→ bisect_on_function_error の動作を混入異常値で検証できる
```

---

### 3-2. Kinesis Data Streams (`terraform/modules/kinesis/`)

```
┌─────────────────────────────────────────┐
│         Kinesis Data Streams            │
│         iot-pipeline-stream             │
│                                         │
│  mode: ON_DEMAND                        │
│  → シャード数を自動スケール             │
│  → 事前のキャパシティ見積もり不要       │
│                                         │
│  retention: 24時間                      │
│  → Lambda失敗時にリトライ可能な期間     │
│  → それ以上は再処理コストより削除が安い │
│                                         │
│  PartitionKey: device_id                │
│  → デバイスごとにシャードが決まる       │
│  → 同一デバイスのレコード順序が保証     │
└─────────────────────────────────────────┘
```

**KinesisとSQSの違い（面接頻出）:**

| 観点 | Kinesis | SQS |
|---|---|---|
| 順序保証 | シャード内で保証 | FIFOキューのみ |
| 消費者 | 複数コンシューマが同一データを読める | 1消費者が読んだら削除 |
| 保持期間 | 最大365日 | 最大14日 |
| 処理単位 | バッチ（シーケンシャル） | メッセージ単体 |
| ユースケース | ログ収集・IoT・リアルタイム分析 | タスクキュー・非同期処理 |

→ **このプロジェクトがKinesisを選んだ理由**: 同一デバイスのデータ順序保証とON_DEMANDモードのスケーラビリティ

---

### 3-3. Lambda processor (`lambda/processor/`)

```
┌─────────────────────────────────────────┐
│         Lambda: iot-pipeline-processor  │
│                                         │
│  runtime: Python 3.12 (container)       │
│  arch:    arm64 (Graviton2)             │
│  timeout: 60秒                          │
│  memory:  256MB                         │
│                                         │
│  ESM設定:                               │
│    batch_size: 100件                    │
│    window:     10秒                     │
│    bisect:     true ← 重要             │
└─────────────────────────────────────────┘
```

**Event Source Mapping (ESM) の動作:**

```
Kinesis シャード
  │
  │ ポーリング (Lambdaサービスが自動実行)
  ▼
┌──────────────────────────────────────────┐
│  バッチ収集                              │
│  条件1: 100件貯まった                    │
│  条件2: 10秒経過した                     │
│  → どちらか早い方でLambdaを起動          │
└──────────────────────────────────────────┘
  │
  ▼
Lambda起動 → 処理 → 結果返却
  │
  ├─ 全件成功 → {"batchItemFailures": []}
  │             Kinesisのカーソルを進める
  │
  └─ 一部失敗 → {"batchItemFailures": [{"itemIdentifier": "seq_no"}]}
                bisect_on_function_error=true が発動
                → バッチを2分割してリトライ
                → 失敗原因の1件が特定できるまで分割継続
```

**ZIPデプロイとコンテナデプロイの比較（ADR-001参照）:**

| 観点 | ZIP | コンテナ |
|---|---|---|
| デプロイサイズ上限 | 50MB (直接) / 250MB (展開後) | 10GB |
| ローカル再現性 | 環境差異が生じやすい | `docker run` で完全再現 |
| ビルドパイプライン | requirements.txtのzip化が必要 | Dockerfile 1本で完結 |
| コールドスタート | やや速い | 初回はやや遅い（イメージPull） |
| このプロジェクトの選択理由 | — | ローカル動作確認のしやすさ優先 |

---

### 3-4. DynamoDB (`terraform/modules/dynamodb/`)

```
┌─────────────────────────────────────────────┐
│    テーブル: iot-pipeline-table             │
│                                             │
│  PK (Hash Key):  device_id  (String)        │
│  SK (Sort Key):  timestamp  (String)        │
│                                             │
│  その他属性:                                │
│    temperature  Number (Decimal)            │
│    humidity     Number (Decimal)            │
│    status       String                      │
│    expires_at   Number (Unix秒)  ← TTL     │
│                                             │
│  billing_mode: PAY_PER_REQUEST              │
│  TTL: expires_at (72時間後に自動削除)        │
└─────────────────────────────────────────────┘
```

**キー設計の理由:**

```
アクセスパターン: 「デバイスIDを指定して最新N件を取得する」

→ device_id をハッシュキーにする
  → デバイスごとのデータが同一パーティションに集まる
  → デバイス単位のクエリが効率的

→ timestamp をソートキーにする
  → パーティション内で時系列ソートが保証される
  → ScanIndexForward=False で最新データを先頭に取得可能

❌ device_id だけをハッシュキーにして timestamp を除いた場合
  → 同一device_idに1件しか保存できない（上書きになる）

❌ timestamp だけをハッシュキーにした場合
  → デバイスIDでのフィルタにScanが必要（全件スキャン=低速・高コスト）
```

**TTL (Time to Live) の仕組み:**
```
書き込み時: expires_at = int(time.time()) + 72*3600

DynamoDBのTTL機能が定期的にスキャンし、
expires_at < 現在時刻 のアイテムを自動削除する

→ ハンズオンデータが蓄積してストレージコストが増えない
→ 削除はバックグラウンド処理なので、TTL経過後も数分〜数時間残ることがある
```

---

### 3-5. ECR (`terraform/modules/ecr/`)

```
┌──────────────────────────┐  ┌──────────────────────────┐
│  iot-pipeline-processor  │  │  iot-pipeline-reader     │
│                          │  │                          │
│  scan_on_push: true      │  │  scan_on_push: true      │
│  ライフサイクルポリシー   │  │  ライフサイクルポリシー   │
│  → 最新1世代のみ保持     │  │  → 最新1世代のみ保持     │
└──────────────────────────┘  └──────────────────────────┘
```

**ライフサイクルポリシーがなぜ重要か:**
```
ECRの課金: $0.10 / GB・月

ライフサイクルなし → イメージが毎デプロイで蓄積
  例: 500MB × 20回デプロイ = 10GB → $1/月

ライフサイクルあり (最新1件のみ)
  例: 500MB × 1件 = 0.5GB → $0.05/月
```

---

### 3-6. API Gateway (`terraform/modules/apigateway/`)

```
REST API: iot-pipeline-api
  │
  ├── /sensors
  │     └── /{device_id}
  │           └── GET  ───▶ Lambda (reader) Proxy統合
  │
  Stage: v1
    → invoke_url: https://{id}.execute-api.ap-northeast-1.amazonaws.com/v1
    → アクセスログ: /aws/apigateway/iot-pipeline (CloudWatch, 7日保持)
```

**Lambda Proxy統合とは:**
```
Proxy統合あり (このプロジェクト):
  API GW → Lambdaにリクエスト全体を渡す
  Lambda → {"statusCode": 200, "headers": {}, "body": "..."} を返す
  API GW → Lambdaのレスポンスをそのままクライアントへ
  → マッピングテンプレート不要、Lambdaが完全制御

Proxy統合なし:
  API GW側でリクエスト/レスポンスの変換テンプレートを書く必要がある
  → 設定が複雑、Lambda実装はシンプルになるがインフラ側の管理コストが上がる
```

**`integration_http_method = "POST"` のなぜ:**
```
API GatewayがLambdaを呼び出す際は、クライアントのHTTPメソッドに関係なく
常に POST でLambdaのInvoke APIを叩く（AWS仕様）。
クライアントが GET でリクエストしても、API GW → Lambda間は POST。
```

---

### 3-7. Lambda reader (`lambda/reader/`)

```python
# DynamoDBからDecimal型で返ってくる数値をJSONシリアライズする
# Pythonのjson.dumps()はDecimalを扱えないため変換が必要
def decimal_to_float(obj):
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError(...)

# ScanIndexForward=False の意味
# DynamoDBはソートキー昇順(古い順)がデフォルト
# Falseにすることで降順(新しい順)になる
response = table.query(
    KeyConditionExpression=Key("device_id").eq(device_id),
    ScanIndexForward=False,  ← 最新データを先頭に
    Limit=limit,
)
```

---

## 4. IAM設計

### 最小権限の実装

```
processor Lambda ロール
├── logs:CreateLogGroup
├── logs:CreateLogStream        → /aws/lambda/iot-pipeline-processor のみ
├── logs:PutLogEvents
├── kinesis:GetRecords
├── kinesis:GetShardIterator    → iot-pipeline-stream ARN のみ
├── kinesis:DescribeStream
├── kinesis:ListShards
├── kinesis:ListStreams
├── dynamodb:PutItem            → iot-pipeline-table ARN のみ
└── dynamodb:BatchWriteItem

reader Lambda ロール
├── logs:CreateLogGroup
├── logs:CreateLogStream        → /aws/lambda/iot-pipeline-reader のみ
├── logs:PutLogEvents
├── dynamodb:GetItem            → iot-pipeline-table ARN のみ
└── dynamodb:Query
```

**意図的に除いた権限:**
```
processor:
  × dynamodb:GetItem, Query   → 書き込み専用、読み取り不要
  × kinesis:PutRecord         → 自分でストリームに書き戻さない

reader:
  × dynamodb:PutItem          → 読み取り専用、書き込み不可
  × kinesis:*                 → Kinesisには一切触れない
```

**ハードコード回避:**
```hcl
# ❌ NGパターン
Resource = "arn:aws:dynamodb:ap-northeast-1:123456789012:table/iot-pipeline-table"

# ✅ このプロジェクトのパターン
data "aws_caller_identity" "current" {}
Resource = var.dynamodb_table_arn  ← moduleのoutputから取得
```

---

## 5. コスト設計

### 各サービスのコスト特性

```
┌─────────────────────────────────────────────────────┐
│ Kinesis Data Streams (ON_DEMAND)                    │
│   PUT: $0.014 / 1,000,000件                         │
│   取得: $0.014 / 1,000,000件                         │
│   シミュレータ120秒 × 5デバイス × 0.5req/sec = 300件│
│   → ほぼ無料                                        │
├─────────────────────────────────────────────────────┤
│ Lambda (arm64)                                      │
│   x86_64比で約20%安価                               │
│   processor: 256MB, ~50ms/バッチ                    │
│   reader:    128MB, ~20ms/リクエスト                │
│   → 無料枠内 (月100万リクエスト, 400,000GB-秒)      │
├─────────────────────────────────────────────────────┤
│ DynamoDB (PAY_PER_REQUEST)                          │
│   書き込み: $1.4269 / 100万WCU (ap-northeast-1)    │
│   読み取り: $0.285 / 100万RCU                       │
│   ハンズオン規模: ほぼ無料                          │
├─────────────────────────────────────────────────────┤
│ API Gateway (REST)                                  │
│   $3.50 / 100万リクエスト                           │
│   テスト規模: ほぼ無料                              │
├─────────────────────────────────────────────────────┤
│ ECR                                                 │
│   $0.10 / GB・月                                    │
│   ライフサイクルポリシーで最新1件のみ保持           │
│   → ~$0.05/月                                       │
└─────────────────────────────────────────────────────┘

禁止事項: NAT Gateway ($32/月固定) は使用しない
→ LambdaはVPC外に配置 (インターネット経由でAWSサービスにアクセス)
```

---

## 6. エラーハンドリング設計

### bisect_on_function_error の動作詳細

```
シナリオ: バッチ100件中、シーケンス番号50の1件が不正データ

試行1: [1〜100] → 失敗
       bisect発動 → 2分割
試行2: [1〜50]  → 失敗 (50が含まれるため)
       bisect発動 → 2分割
試行3: [1〜25]  → 成功 ✅ (カーソル進む)
試行4: [26〜50] → 失敗
       bisect発動 → 2分割
試行5: [26〜38] → 成功 ✅
試行6: [39〜50] → 失敗
       bisect発動 → 2分割
       ...
最終:  [50]     → 失敗 (1件のみ)
       → DLQ (Dead Letter Queue) 送信 または 保持期間超過でスキップ
       → [51〜100] は成功 ✅

→ 1件の不正データでバッチ全体が止まらない
```

**bisect がない場合:**
```
[1〜100] → 失敗
[1〜100] → 失敗 (リトライ)
...
保持期間(24時間)超過 → 全100件がスキップ or 無限リトライ
→ 1件の問題で99件の正常データが損失する可能性
```

### Lambda の部分失敗レポート

```python
# processor/app.py の戻り値設計
return {
    "batchItemFailures": [
        {"itemIdentifier": "シーケンス番号"}  # 失敗したレコードのみ
    ]
}

# 全件成功時:
return {"batchItemFailures": []}  # 空リスト

# KinesisはitemIdentifierのシーケンス番号以降から再処理する
# → 成功済みのレコードを二重処理しない
```

---

## 7. ディレクトリ構成と責務

```
iot-stream-pipeline/
│
├── terraform/                    # インフラ定義
│   ├── main.tf                   # ルートモジュール (モジュール呼び出しと依存関係)
│   ├── variables.tf              # image URI等の外部入力変数
│   ├── outputs.tf                # 他フェーズへ渡す値 (API endpoint等)
│   └── modules/
│       ├── kinesis/              # ストリーム定義
│       ├── dynamodb/             # テーブル + TTL定義
│       ├── ecr/                  # コンテナリポジトリ + ライフサイクル
│       ├── lambda/               # 2つのLambda + ESM + IAMロール
│       └── apigateway/           # REST API + ステージ + CloudWatchログ
│
├── lambda/
│   ├── processor/
│   │   ├── app.py                # Kinesis→DynamoDB書き込みロジック
│   │   ├── Dockerfile            # arm64ベースイメージ
│   │   └── requirements.txt      # aws-lambda-powertools, boto3
│   └── reader/
│       ├── app.py                # DynamoDB読み取り + API Proxyレスポンス
│       ├── Dockerfile
│       └── requirements.txt
│
├── simulator/
│   └── sensor_simulator.py       # 5デバイス並列送信 + 統計出力
│
├── scripts/
│   ├── push_images.sh            # ECRへのDockerイメージビルド&プッシュ
│   └── e2e_test.sh               # Kinesis送信→DynamoDB確認→API確認
│
└── docs/
    └── adr/
        └── ADR-001-container-lambda.md  # コンテナ選択の判断記録
```

**モジュール間の依存関係:**

```
kinesis ──────────────────────────────▶ lambda
                                        (kinesis_stream_arn)
dynamodb ────────────────────────────▶ lambda
                                        (dynamodb_table_name, table_arn)
ecr      → image URI はTerraform外 ──▶ lambda
           (push_images.sh でビルド)    (processor_image_uri, reader_image_uri)
lambda ──────────────────────────────▶ apigateway
                                        (reader_invoke_arn, reader_function_name)
```

---

## 8. フェーズ別構築順序

```
Phase 1: 基盤インフラ
  ┌─────────────────────────────────────┐
  │  Kinesis + DynamoDB + ECR を作成   │
  │  terraform apply                    │
  │  terraform output -json > phase1_outputs.json │
  └─────────────────────────────────────┘
         ↓
Phase 2: コンテナビルド & Lambda デプロイ
  ┌─────────────────────────────────────┐
  │  scripts/push_images.sh を実行      │
  │  → ECR に processor/reader をPush  │
  │  → phase2_image_uris.env に保存    │
  │                                     │
  │  source phase2_image_uris.env       │
  │  terraform apply                    │
  │  (Lambda + ESM が作成される)        │
  └─────────────────────────────────────┘
         ↓
Phase 3: API Gateway デプロイ
  ┌─────────────────────────────────────┐
  │  terraform apply (idempotent)       │
  │  terraform output -json > phase3_outputs.json │
  │  → api_endpoint が確定する          │
  └─────────────────────────────────────┘
         ↓
Phase 4: E2E テスト & クリーンアップ
  ┌─────────────────────────────────────┐
  │  python3 simulator/sensor_simulator.py &      │
  │  sleep 30                           │
  │  ./scripts/e2e_test.sh              │
  │                                     │
  │  # 完了後に全リソース削除           │
  │  terraform destroy                  │
  └─────────────────────────────────────┘
```

**なぜimage URIがTerraform外か:**
```
Terraform の制約:
  terraform plan/apply の時点でimage URIが確定している必要がある。
  しかしECRリポジトリはTerraformで作成するため、
  「リポジトリ作成 → イメージPush → LambdaデプロイでURI参照」
  という順序が必要になる。

解決策:
  Phase1でECRリポジトリを作成 → Phase2でイメージをPush
  → image URIをvariableとして外部からTerraformに渡す
```

---

## 9. 面接トーキングポイント

### Q: なぜKinesisを使ったか (SQSではなく)

```
理由1: 順序保証
  同一device_idのレコードがPartitionKeyによって同一シャードに入るため、
  センサーデータの時系列順序が保証される。

理由2: 複数コンシューマ対応
  将来的に分析用のLambdaを追加しても、同一ストリームから独立して消費できる。
  SQSでは1消費者が読んだメッセージは削除される。

理由3: リプレイ能力
  保持期間内(24時間)であれば、Lambdaのバグ修正後に
  同じレコードを再処理できる。
```

### Q: bisect_on_function_error がない場合どうなるか

```
不正なレコードを含むバッチが繰り返しリトライされ、
Kinesisの保持期間(24時間)が切れるまでそのシャードの処理が止まる。
→ 後続の正常なレコードも処理されない
→ DynamoDBへの書き込みが全停止

bisect を使うことで:
→ 不正なレコード1件を特定・隔離
→ 正常なレコードは継続処理
→ 部分的な失敗が全体を止めない (フォールトアイソレーション)
```

### Q: このパイプラインを1000台規模にスケールするには

```
Kinesis:
  ON_DEMANDモードのため自動スケール (追加設定不要)
  ただし1シャード=1MB/sの制限があるため、
  デバイス数×送信頻度がシャードあたりの上限を超えないか確認する

Lambda:
  ESMの同時実行数をシャード数に合わせて自動スケール
  concurrency の上限をアカウントのデフォルト(1000)に注意

DynamoDB:
  PAY_PER_REQUESTのため自動スケール
  ただしホットパーティション対策として
  device_idにランダムサフィックスを追加するWrite Shardingを検討

API Gateway:
  デフォルトで10,000 req/sまでスケール
  それ以上はLimitリクエストが必要
```

### Q: コールドスタートの影響と対策

```
現状:
  コンテナイメージのLambdaはZIPよりコールドスタートが遅い (1〜3秒)
  processor: Kinesisイベント駆動なので多少遅くても許容範囲
  reader:    APIリクエスト駆動なので体感に影響する可能性あり

対策オプション:
  1. Provisioned Concurrency: 常時warm状態を維持 (コスト増)
  2. Lambda SnapStart: Java向け、Pythonは未対応
  3. 軽量ベースイメージ: AWS提供のpython:3.12-arm64は既に最適化済み
  4. 定期的なwarm-up ping: EventBridgeで5分ごとに呼び出す

このプロジェクトの選択:
  ハンズオン用途のためコスト優先 → 対策なし
```

### E2Eで計測すべき数値

```
1. Kinesis → DynamoDB レイテンシ
   測定方法: put_record の直後から DynamoDB get-item で確認できるまでの時間
   目安: 数秒〜30秒 (Lambdaのバッチウィンドウ10秒が支配的)

2. API Gateway レイテンシ
   測定方法: curl -w "%{time_total}" で計測
   目安: 100ms〜500ms (Lambdaコールドスタートなしの場合)

3. シミュレータ成功率
   測定方法: stats["success"] / (stats["success"] + stats["failure"])
   目標: 99%以上 (IAM権限・ネットワーク設定が正しければ達成可能)
```
