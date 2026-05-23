# Architecture — ai-inference-pipeline

## 目次

1. [システム概要](#1-システム概要)
2. [全体アーキテクチャ図](#2-全体アーキテクチャ図)
3. [データフロー詳細](#3-データフロー詳細)
4. [コンポーネント解説](#4-コンポーネント解説)
   - [S3（データ入出力）](#41-s3データ入出力)
   - [EventBridge（トリガー）](#42-eventbridgeトリガー)
   - [Step Functions（オーケストレーター）](#43-step-functionsオーケストレーター)
   - [ECS Fargate（前処理コンテナ）](#44-ecs-fargate前処理コンテナ)
   - [Lambda / Bedrock（AI推論）](#45-lambda--bedrockai推論)
   - [Lambda / Chatwork（通知）](#46-lambda--chatwork通知)
   - [DynamoDB（結果永続化）](#47-dynamodb結果永続化)
   - [VPC Endpoints（ネットワーク）](#48-vpc-endpointsネットワーク)
   - [IAM（権限管理）](#49-iam権限管理)
5. [ネットワーク設計](#5-ネットワーク設計)
6. [エラーハンドリング](#6-エラーハンドリング)
7. [セキュリティ設計](#7-セキュリティ設計)
8. [コスト設計](#8-コスト設計)
9. [Terraform構成](#9-terraform構成)
10. [命名規則とARNパターン](#10-命名規則とarnパターン)

---

## 1. システム概要

S3にファイルをアップロードするだけで、自動的にデータ前処理 → AI推論 → 結果通知まで
一気通貫で実行されるイベント駆動型パイプライン。

| 項目 | 内容 |
|---|---|
| リージョン | ap-northeast-1（東京） |
| 環境 | dev |
| IaC | Terraform |
| アーキテクチャ | フルサーバーレス（EC2・RDS不使用） |
| コンピュート | arm64（Graviton2）統一 |
| AI | Amazon Bedrock（Claude 3 Haiku） |

---

## 2. 全体アーキテクチャ図

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  AWS VPC（プライベートサブネット）                                              │
│                                                                             │
│  ┌─────────┐   EventBridge   ┌──────────────────────────────────────────┐  │
│  │   S3    │ ──────────────► │         Step Functions                   │  │
│  │ input/  │  Object Created │         aip-dev-inference-pipeline        │  │
│  └─────────┘                 │                                           │  │
│                              │  ┌────────────────────────────────────┐  │  │
│  ┌─────────┐                 │  │  1. GenerateJobId  (Pass)          │  │  │
│  │   S3    │◄──────────────  │  │  2. RunPreprocessor (ECS sync)     │  │  │
│  │ output/ │   前処理結果     │  │  3. ExtractOutputKey (Pass)        │  │  │
│  └─────────┘                 │  │  4. InvokeBedrock  (Lambda)        │  │  │
│       │                      │  │  5. NotifySuccess  (Lambda)        │  │  │
│       │                      │  │     ／NotifyFailure (Lambda)       │  │  │
│       ▼                      │  └────────────────────────────────────┘  │  │
│  ┌──────────────────────┐    └──────────────────────────────────────────┘  │
│  │  ECS Fargate         │              │              │                     │
│  │  preprocessor        │◄─────────── │  ────────────┤                     │
│  │  (arm64, Spot)       │    RunTask   │              │                     │
│  └──────────────────────┘             │              │                     │
│                                       │              │                     │
│  ┌──────────────────────┐             │              │                     │
│  │  Lambda              │◄────────────┘              │                     │
│  │  invoke_bedrock      │                            │                     │
│  │  (arm64, py3.12)     │─── Bedrock API ──►  ┌─────────────┐            │
│  └──────────────────────┘                      │   Bedrock   │            │
│          │                                     │ Claude Haiku│            │
│          │ PutItem                             └─────────────┘            │
│          ▼                                                                 │
│  ┌──────────────────────┐             │                                    │
│  │  DynamoDB            │             │                                    │
│  │  aip-dev-results     │             │                                    │
│  └──────────────────────┘             │                                    │
│                                       │                                    │
│  ┌──────────────────────┐             │                                    │
│  │  Lambda              │◄────────────┘                                    │
│  │  notify_chatwork     │                                                  │
│  │  (arm64, py3.12)     │─── HTTPS ──► Chatwork API（外部）                │
│  └──────────────────────┘                                                  │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  VPC Endpoints（NAT Gateway不使用）                                   │  │
│  │  Gateway型: S3, DynamoDB（無料）                                      │  │
│  │  Interface型: ECR, Logs, SSM, STS, Bedrock, States, ECS（有料）      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

┌────────────────┐
│  SSM Parameter │  ◄── notify_chatwork が Chatwork Token を取得
│  Store         │
└────────────────┘
```

---

## 3. データフロー詳細

### 正常系フロー

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 1: ファイルアップロード                                               │
│                                                                          │
│  User / CI                                                               │
│    └─► PUT s3://aip-dev-input-{account}/input/data.csv                  │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 2: EventBridge トリガー                                              │
│                                                                          │
│  EventBridge Event（S3 Object Created）                                   │
│    source:       "aws.s3"                                                │
│    detail-type:  "Object Created"                                        │
│    detail.bucket.name: "aip-dev-input-{account}"                        │
│    detail.object.key:  "input/data.csv"          ← prefix フィルタ       │
│                                                                          │
│  Input Transformer で変換:                                                │
│    { "input_bucket": "aip-dev-input-...", "s3_key": "input/data.csv" }  │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 3: Step Functions 実行開始                                           │
│                                                                          │
│  [GenerateJobId] ── Pass state                                           │
│    入力: { input_bucket, s3_key }                                        │
│    処理: States.UUID() で job_id を生成                                   │
│    出力: { job_id: "550e8400-...", input_bucket, s3_key }                │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 4: ECS Fargate 前処理（同期待機）                                    │
│                                                                          │
│  [RunPreprocessor] ── ECS runTask.sync:2                                 │
│    コンテナ: aip/dev/preprocessor:latest（ECRから取得）                   │
│    オーバーライド:                                                         │
│      S3_KEY  = "input/data.csv"                                          │
│      JOB_ID  = "550e8400-..."                                            │
│                                                                          │
│  preprocessor/main.py の処理:                                            │
│    1. S3 GetObject: input/data.csv を取得                                │
│    2. CSV/JSON パース（pandas）                                           │
│    3. 空行削除・空白トリム・正規化                                          │
│    4. S3 PutObject: processed/data.json を出力                           │
│    5. 完了ログを stdout に JSON 出力（SFN が受け取る）                    │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 5: 出力キー解決                                                      │
│                                                                          │
│  [ExtractOutputKey] ── Pass state                                        │
│    input/data.csv → processed/data.json へパス変換                       │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 6: Bedrock 推論                                                      │
│                                                                          │
│  [InvokeBedrock] ── Lambda invoke                                        │
│    invoke_bedrock/main.py の処理:                                         │
│    1. S3 GetObject: processed/data.json を取得                           │
│    2. プロンプト構築:                                                     │
│       「以下のデータを分析し JSON で回答してください。                       │
│         summary / key_themes / categories /                              │
│         recommendations / data_quality を含めること」                    │
│    3. bedrock-runtime InvokeModel（Claude 3 Haiku）                      │
│    4. DynamoDB PutItem（結果 + TTL 7日）                                 │
│    5. Step Functions に inference_result を返す                          │
└──────────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ Step 7: Chatwork 通知                                                     │
│                                                                          │
│  [NotifySuccess] ── Lambda invoke                                        │
│    notify_chatwork/main.py の処理:                                        │
│    1. SSM GetParameter: /aip/dev/chatwork/token（SecureString）          │
│    2. メッセージ整形（Chatwork マークアップ）:                             │
│       [info][title]✅ AI推論パイプライン完了[/title]                       │
│       Job ID: 550e8400-...                                               │
│       データ品質: high                                                    │
│       主要テーマ: ...[/info]                                              │
│    3. Chatwork API POST:                                                  │
│       https://api.chatwork.com/v2/rooms/{room_id}/messages               │
└──────────────────────────────────────────────────────────────────────────┘
```

### 異常系フロー

```
[RunPreprocessor] が失敗した場合
  └─ Retry（最大2回、30秒待機、指数バックオフ 2.0x）
       └─ 全試行失敗 → Catch → [NotifyFailure]
                                   └─ Chatwork に ❌ メッセージ送信
                                   └─ [PipelineFailed] Fail state で終了

[InvokeBedrock] が失敗した場合
  └─ Retry（最大3回、10秒待機、指数バックオフ ※Bedrockスロットリング対策）
       └─ 全試行失敗 → Catch → [NotifyFailure]
                                   └─ 同上

[NotifySuccess/Failure] が失敗した場合
  └─ パイプライン全体は成功扱い（通知はベストエフォート）
  └─ エラーは CloudWatch Logs に記録
```

---

## 4. コンポーネント解説

### 4.1 S3（データ入出力）

```
aip-dev-input-{account_id}          aip-dev-output-{account_id}
├── input/                          ├── processed/
│   ├── data.csv   ◄── ここに投入   │   └── data.json  ◄── ECSが書き出す
│   └── ...                        └── ...
└── （prefix: input/ のみトリガー）
```

| 設定 | 値 | 理由 |
|---|---|---|
| パブリックアクセス | 完全ブロック | 機密データ保護 |
| EventBridge通知 | 有効（inputバケットのみ） | トリガー連携 |
| バージョニング | 無効 | コスト削減（dev環境） |
| Force Destroy | true | 開発用途（本番では false） |

### 4.2 EventBridge（トリガー）

```
S3イベント ──► EventBridge Rule ──► Step Functions
              (フィルタ条件)         (Input Transformer)

フィルタ条件:
  source:      "aws.s3"
  detail-type: "Object Created"
  bucket.name: "aip-dev-input-{account}"
  object.key:  prefix "input/"  ← サブフォルダへの誤投入を防ぐ

変換後の出力（SFNへの入力）:
  {
    "input_bucket": "<bucket>",
    "s3_key": "<key>"
  }
```

**設計ポイント**: `input/` プレフィックスフィルタにより、
`processed/` に書き出された後処理ファイルが再度トリガーされる無限ループを防止。

### 4.3 Step Functions（オーケストレーター）

**ステートマシン定義（概要）**:

```
                    ┌─────────────┐
                    │GenerateJobId│  Pass: States.UUID() 生成
                    └──────┬──────┘
                           │
                    ┌──────▼──────────┐
                    │RunPreprocessor  │  ECS runTask.sync:2
                    │                 │  Retry: 2回 / 30s / 2.0x
                    └──────┬──────────┘
                    Catch  │  成功
                      │    ▼
                      │  ┌─────────────────┐
                      │  │ExtractOutputKey │  Pass
                      │  └──────┬──────────┘
                      │         │
                      │  ┌──────▼──────────┐
                      │  │InvokeBedrock    │  Lambda invoke
                      │  │                 │  Retry: 3回 / 10s / 2.0x
                      │  └──────┬──────────┘
                      │  Catch  │  成功
                      │    │    ▼
                      │    │  ┌──────────────┐
                      │    │  │NotifySuccess │  Lambda invoke
                      │    │  └──────┬───────┘
                      │    │         │
                      │    │       [END]
                      │    │
                      ▼    ▼
                    ┌─────────────┐
                    │NotifyFailure│  Lambda invoke
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │PipelineFailed│  Fail state
                    └─────────────┘
```

| 設定 | 値 | 理由 |
|---|---|---|
| タイプ | STANDARD | 90日履歴保持・デバッグ重視（Expressは1日のみ） |
| ログレベル | ALL | 全ステートの入出力を記録 |
| X-Ray | 有効 | ステートごとのレイテンシ可視化 |

### 4.4 ECS Fargate（前処理コンテナ）

```
┌─────────────────────────────────────────────────────┐
│  ECS Cluster: aip-dev-cluster                       │
│                                                     │
│  ┌─────────────────────────────────────────────┐   │
│  │  Task Definition: aip-dev-preprocessor      │   │
│  │                                             │   │
│  │  CPU:    256  (0.25 vCPU)                   │   │
│  │  Memory: 512  MB                            │   │
│  │  Arch:   ARM64 (Graviton2)                  │   │
│  │                                             │   │
│  │  Container: preprocessor                    │   │
│  │    Image:   {ecr}/aip/dev/preprocessor      │   │
│  │    Env:     INPUT_BUCKET, OUTPUT_BUCKET      │   │
│  │    Env(override): S3_KEY, JOB_ID            │   │
│  │    Log:     /aip/dev/ecs/preprocessor       │   │
│  └─────────────────────────────────────────────┘   │
│                                                     │
│  Capacity Providers:                                │
│    FARGATE_SPOT: weight=4  (80% 優先)              │
│    FARGATE:      weight=1  (fallback)               │
└─────────────────────────────────────────────────────┘
```

**preprocessor/main.py の処理フロー**:

```python
main()
  ├─ 環境変数から INPUT_BUCKET, OUTPUT_BUCKET, S3_KEY, JOB_ID 取得
  ├─ S3 から raw data 取得（JSON/CSV 自動判定）
  ├─ pandas DataFrame に変換
  ├─ 前処理:
  │    - 空行削除（dropna）
  │    - 文字列フィールドの空白トリム
  │    - カラム一覧・レコード数を集計
  ├─ output_key を算出: input/xxx.csv → processed/xxx.json
  ├─ 前処理済みデータを S3 PutObject
  └─ 結果を JSON で stdout 出力（Step Functions が受け取る）
       { status, job_id, output_key, record_count }
```

### 4.5 Lambda / Bedrock（AI推論）

```
invoke_bedrock/main.py

handler(event)
  │  event: { job_id, output_key }
  │
  ├─ S3 GetObject: output/processed/xxx.json
  ├─ build_prompt(data)
  │    └─ 分析指示 + データを結合したプロンプト文字列を生成
  │       （summary / key_themes / categories /
  │         recommendations / data_quality を JSON で返すよう指示）
  │
  ├─ bedrock_runtime.invoke_model()
  │    model_id:  anthropic.claude-3-haiku-20240307-v1:0
  │    max_tokens: 1000
  │    messages:  [{ role: user, content: prompt }]
  │
  ├─ レスポンスの JSON パース（失敗時は raw text を格納）
  │
  ├─ DynamoDB PutItem
  │    job_id, created_at, status="completed",
  │    inference_result, model_id, expires_at(+7日)
  │
  └─ return { status, job_id, inference_result }
```

**Powertools 統合**:
```python
@tracer.capture_lambda_handler   # X-Ray トレース
@logger.inject_lambda_context    # 構造化ログ（request_id 等を自動付与）
def handler(event, context):
    ...
```

### 4.6 Lambda / Chatwork（通知）

```
notify_chatwork/main.py

handler(event)
  │  event: { status, job_id, inference_result? , error? }
  │
  ├─ SSM GetParameter: /aip/dev/chatwork/token（SecureString → 復号）
  ├─ format_message(event)
  │    成功: ✅ AI推論パイプライン完了
  │           Job ID / データ品質 / 主要テーマ / サマリー
  │    失敗: ❌ AI推論パイプライン失敗
  │           Job ID / エラー詳細
  │
  ├─ POST https://api.chatwork.com/v2/rooms/{room_id}/messages
  │    Header: X-ChatWorkToken: {token}
  │    Body:   body={message}  (application/x-www-form-urlencoded)
  │
  └─ return { status: "notified" }
```

**urllib 使用（外部ライブラリ不要）**:
Lambda の Lambda Layer や追加依存なしで Chatwork API に接続できる設計。

### 4.7 DynamoDB（結果永続化）

```
Table: aip-dev-results

┌─────────────────────────────────────────────────────┐
│  PK(Hash): job_id    (String, UUID)                 │
│  SK(Sort): created_at (String, ISO8601 JST)         │
│                                                     │
│  status           "completed" or "failed"           │
│  record_count     前処理済みレコード数               │
│  source_key       元ファイルのS3キー                 │
│  inference_result { summary, key_themes, ... }      │
│  model_id         "anthropic.claude-3-haiku-..."    │
│  expires_at       Unix timestamp（7日後）           │
└─────────────────────────────────────────────────────┘

GSI: status-index
  Hash:  status       → ステータス別クエリ用
  Sort:  created_at   → 時系列ソート用
  例: 「直近1時間の完了ジョブ一覧」
```

| 設定 | 値 | 理由 |
|---|---|---|
| 課金モード | PAY_PER_REQUEST | アクセス量が予測不能な開発用途 |
| TTL | expires_at（7日） | 古い結果を自動削除してコスト削減 |
| PITR | 有効 | 誤削除からの復元に備える |

### 4.8 VPC Endpoints（ネットワーク）

```
プライベートサブネット内のリソースが AWS サービスへアクセスする経路:

                          ┌──────────────────────────────┐
ECS / Lambda              │  VPC Endpoints               │
    │                     │                              │
    ├── S3 アクセス ──────►│  Gateway型（無料）            │──► S3
    │                     │    com.amazonaws.*.s3        │
    ├── DynamoDB ─────────►│    com.amazonaws.*.dynamodb  │──► DynamoDB
    │                     │                              │
    ├── ECR イメージ Pull ─►│  Interface型（有料）          │──► ECR
    │                     │    ecr.api                   │
    │                     │    ecr.dkr                   │
    ├── CloudWatch Logs ──►│    logs                      │──► CloudWatch
    ├── SSM ──────────────►│    ssm                       │──► SSM
    ├── STS ──────────────►│    sts                       │──► STS
    ├── Bedrock ──────────►│    bedrock-runtime           │──► Bedrock
    ├── Step Functions ───►│    states                    │──► SFN
    └── ECS 制御 ─────────►│    ecs / ecs-agent           │──► ECS
                           │    ecs-telemetry             │
                           └──────────────────────────────┘

Private DNS 有効 → SDK は通常のエンドポイントを使うだけで自動的に
                   VPC Endpoint 経由にルーティングされる（コード変更不要）
```

**NAT Gateway を使わない理由**:
- NAT Gateway: 約 $32/月（固定費 $0.045/h × 720h）
- VPC Endpoints: 約 $7/月（Interface 型 13個 × $0.014/h × AZ数）
- データ転送コスト: Gateway 型（S3, DynamoDB）は無料

### 4.9 IAM（権限管理）

```
IAMロール一覧と権限範囲:

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-ecs-execution-role                                     │
│ Principal: ecs-tasks.amazonaws.com                                   │
│ 用途: ECS がイメージを Pull し、ログを書き込む                         │
│ Policy: AmazonECSTaskExecutionRolePolicy（AWS管理）                   │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-ecs-task-role                                          │
│ Principal: ecs-tasks.amazonaws.com                                   │
│ 用途: コンテナが S3 の読み書きを行う                                  │
│ 許可:                                                                │
│   s3:GetObject  → aip-dev-input-{account}/*  （読み取り専用）         │
│   s3:PutObject  → aip-dev-output-{account}/* （書き込み専用）         │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-lambda-bedrock-role                                    │
│ Principal: lambda.amazonaws.com                                      │
│ 用途: invoke_bedrock Lambda が AI推論・DB書き込みを行う              │
│ 許可:                                                                │
│   bedrock:InvokeModel → claude-3-haiku-...(モデルID固定)             │
│   dynamodb:PutItem/GetItem/UpdateItem → aip-dev-results のみ         │
│   s3:GetObject        → aip-dev-output-{account}/* のみ              │
│   ssm:GetParameter    → /aip/* のみ                                  │
│   + AWSLambdaVPCAccessExecutionRole（VPC接続用）                     │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-lambda-notify-role                                     │
│ Principal: lambda.amazonaws.com                                      │
│ 用途: notify_chatwork Lambda がトークンを取得して通知する             │
│ 許可:                                                                │
│   ssm:GetParameter → /aip/*/chatwork/* のみ（最小限）                │
│   + AWSLambdaVPCAccessExecutionRole                                  │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-sfn-role                                               │
│ Principal: states.amazonaws.com                                      │
│ 用途: Step Functions がECS・Lambdaを起動し、ログを書く               │
│ 許可:                                                                │
│   ecs:RunTask      → aip-dev-* のタスク定義のみ                      │
│   ecs:StopTask     → aip-dev-cluster/* のタスクのみ                  │
│   ecs:DescribeTasks → 同上                                           │
│   iam:PassRole     → ECS実行ロール・タスクロールのみ（ARN指定）       │
│   lambda:InvokeFunction → Lambda ARN指定                             │
│   events:PutTargets → ECS完了待機用ルールのみ                        │
│   logs:* → /aip/* ロググループのみ（Delivery系は * 必須）             │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│ Role: aip-dev-eventbridge-role                                       │
│ Principal: events.amazonaws.com                                      │
│ 用途: EventBridge が Step Functions を起動する                       │
│ 許可:                                                                │
│   states:StartExecution → aip-dev-inference-pipeline のARN のみ      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 5. ネットワーク設計

```
VPC: 10.0.0.0/16
  │
  ├── プライベートサブネット（マルチAZ）
  │     ECS Fargate, Lambda が配置される
  │     インターネットへの直接経路なし
  │
  └── （パブリックサブネットなし）
        NAT Gateway 不使用

セキュリティグループ:

┌────────────────────────────────────────────────────┐
│ aip-dev-ecs-sg (ECS Fargate タスク)                │
│   Inbound:  なし（Fargate は受信不要）              │
│   Outbound: 443/tcp → 0.0.0.0/0                   │
│             （VPC Endpoint への HTTPS 通信）        │
└────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────┐
│ aip-dev-lambda-sg (Lambda 関数)                    │
│   Inbound:  なし（Lambda は VPC 内で起動される）    │
│   Outbound: 443/tcp → 0.0.0.0/0                   │
│             （VPC Endpoint + Chatwork API）        │
└────────────────────────────────────────────────────┘

┌────────────────────────────────────────────────────┐
│ VPC Endpoint セキュリティグループ                   │
│   Inbound:  443/tcp ← 10.0.0.0/16 (VPC CIDR)     │
│   Outbound: なし                                   │
└────────────────────────────────────────────────────┘
```

---

## 6. エラーハンドリング

### リトライ設定

| ステート | エラー種別 | リトライ回数 | 待機秒数 | バックオフ |
|---|---|---|---|---|
| RunPreprocessor | ECS.TaskFailed / 全エラー | 2回 | 30秒 | 2.0x |
| InvokeBedrock | Lambda.TooManyRequests / 全エラー | 3回 | 10秒 | 2.0x |

### リトライが有効な理由

```
ECS Fargate の一時的失敗:
  - Fargate Spot の中断（2回まで許容）
  - コンテナ起動のタイムアウト（一時的なネットワーク遅延）

Bedrock スロットリング:
  - Claude の API は同時リクエスト数に上限がある
  - 10秒 × 3回でスロットリングが解消されるケースが多い
  - 指数バックオフで再試行間隔を自動調整
```

### Catch 後のフロー

```
どのステートが失敗しても同じフローへ:
  → NotifyFailure Lambda（Chatwork に ❌ メッセージ）
  → PipelineFailed（Fail state）
  → Step Functions の実行ステータスが "FAILED" になる
  → CloudWatch Logs にエラー詳細が残る
  → Step Functions コンソールで実行履歴を確認可能
```

---

## 7. セキュリティ設計

### シークレット管理

```
Chatwork API Token の管理フロー:

  ユーザー（手動）
    └─ aws ssm put-parameter
         --name /aip/dev/chatwork/token
         --type SecureString
         --value "xxxxx"
         （KMS で暗号化）

  notify_chatwork Lambda 実行時
    └─ ssm.get_parameter(WithDecryption=True)
         → 復号された値をメモリ内でのみ使用
         → ログ・環境変数・DynamoDB には一切書かない
```

### IAM 最小権限の設計原則

```
❌ やりがちなミス            ✅ このプロジェクトの設計
──────────────────────────────────────────────────────
bedrock:*                    bedrock:InvokeModel のみ
Resource: "*"                モデルARNを具体的に指定
s3:*                         GetObject / PutObject を分けて付与
dynamodb:*                   PutItem/GetItem/UpdateItem のみ
```

### ネットワークセキュリティ

```
脅威: コンテナ・Lambdaからの不正な外部通信

対策:
  - プライベートサブネット配置（インターネット直接到達不可）
  - セキュリティグループで Outbound 443 のみ許可
  - Chatwork API 以外への意図しない外部通信は VPC 内で閉じた通信のみ
  - NAT Gateway 不使用 = インターネットゲートウェイへの経路なし
```

---

## 8. コスト設計

### コスト削減の工夫

| 施策 | 月額削減額（概算） | 実装箇所 |
|---|---|---|
| NAT Gateway 不使用 | **▲ $32** | vpc_endpoints モジュール |
| Fargate Spot 80% 優先 | **▲ $10〜20** | ECS capacity providers |
| arm64（Graviton2） | **▲ 20%** | ECS task def + Lambda architectures |
| DynamoDB TTL 7日 | **▲ $1〜2** | DynamoDB TTL 設定 |
| CloudWatch Logs 7日保持 | **▲ $1〜3** | ロググループ retention |
| ECR ライフサイクル（最新3世代） | **▲ $1** | ECR lifecycle policy |
| Bedrock Haiku（vs Sonnet） | **▲ 約60%** | モデルID指定 |

### 月額概算（dev・低負荷）

| サービス | 概算 |
|---|---|
| VPC Endpoints（Interface型 × 13） | $7〜10 |
| ECS Fargate（Spot優先） | $5〜10 |
| Lambda（1000実行/月想定） | $0.20 |
| DynamoDB（オンデマンド） | $0.25 |
| S3（ストレージ + リクエスト） | $0.30 |
| **合計** | **$13〜21/月** |

> Bedrock は従量課金（入出力トークン数）のため別途加算。
> Haiku は $0.00025/1K input tokens と非常に安価。

---

## 9. Terraform構成

```
terraform/
├── environments/dev/
│   ├── main.tf          ← モジュール呼び出し・provider・locals定義
│   ├── variables.tf     ← 入力変数（region, vpc_id, account_id等）
│   ├── outputs.tf       ← 出力値（ECR URL, SFN ARN等）
│   └── terraform.tfvars ← 環境固有の値（機密情報は書かない）
│
└── modules/
    ├── vpc_endpoints/   ← VPC Endpoint（Gateway + Interface）
    ├── s3/              ← Input/Output バケット
    ├── iam/             ← 全IAMロール・ポリシー
    ├── ecr/             ← コンテナレジストリ
    ├── ecs/             ← Fargateクラスタ・タスク定義
    ├── lambda/          ← 2つのLambda関数
    ├── dynamodb/        ← 結果テーブル
    ├── step_functions/  ← ステートマシン定義
    └── eventbridge/     ← S3トリガールール
```

### モジュール依存関係

```
vpc_endpoints ──────────────────────────────────────────────────────┐
                                                                     │
s3 ──────────────────────────────────────────────────────────────┐  │
                                                                  │  │
ecr ──────────────────────────────────────────────────────────┐  │  │
                                                               │  │  │
dynamodb ──────────────────────────────────────────────────┐  │  │  │
                                                            │  │  │  │
iam(phase1) ←── (s3 ARN, dynamodb ARN) ────────────────┐  │  │  │  │
                                                         │  │  │  │  │
ecs ←── (ecr URL, iam role ARN, subnet, sg) ──────────┐ │  │  │  │  │
                                                        │ │  │  │  │  │
lambda ←── (iam role ARN, subnet, sg, dynamodb) ─────┐ │ │  │  │  │  │
                                                       │ │ │  │  │  │  │
step_functions ←── (ecs, lambda ARN, iam role ARN) ──┘ │ │  │  │  │  │
                                                         │ │  │  │  │  │
iam(phase5) ←── (sfn ARN) ─────────────────────────────┘ │  │  │  │  │
（EventBridge用: sfn_arn が確定してから追加）               │  │  │  │  │
                                                           │  │  │  │  │
eventbridge ←── (sfn ARN, iam role ARN, s3 bucket) ───────┘  │  │  │  │
                                                               │  │  │  │
└──────────────────────────── すべてが参照 ────────────────────┘  └──┘  └──┘

※ IAM と EventBridge の循環参照は count = var.sfn_arn != "" ? 1 : 0 で解決
   Phase1-4: sfn_arn = "" → EventBridge IAM ロールを作成しない
   Phase5:   sfn_arn = 実際のARN → 追加で IAM ロールを作成
```

### 共通タグ（locals）

```hcl
locals {
  common_tags = {
    Project    = "ai-inference-pipeline"
    Env        = var.env
    ManagedBy  = "terraform"
  }
}
```

---

## 10. 命名規則とARNパターン

### リソース命名規則

| リソース種別 | パターン | 例 |
|---|---|---|
| S3 バケット | `aip-{env}-{type}-{account_id}` | `aip-dev-input-123456789012` |
| ECR リポジトリ | `aip/{env}/preprocessor` | `aip/dev/preprocessor` |
| ECS クラスター | `aip-{env}-cluster` | `aip-dev-cluster` |
| ECS タスク定義 | `aip-{env}-preprocessor` | `aip-dev-preprocessor` |
| Lambda 関数 | `aip-{env}-{function}` | `aip-dev-invoke-bedrock` |
| IAM ロール | `aip-{env}-{service}-role` | `aip-dev-sfn-role` |
| DynamoDB テーブル | `aip-{env}-results` | `aip-dev-results` |
| Step Functions | `aip-{env}-inference-pipeline` | `aip-dev-inference-pipeline` |
| EventBridge ルール | `aip-{env}-s3-input-trigger` | `aip-dev-s3-input-trigger` |
| CloudWatch LogGroup | `/aip/{env}/{service}` | `/aip/dev/ecs/preprocessor` |
| SSM パラメータ | `/aip/{env}/chatwork/token` | `/aip/dev/chatwork/token` |

### 主要 ARN パターン

```
# S3
arn:aws:s3:::aip-{env}-input-{account_id}
arn:aws:s3:::aip-{env}-output-{account_id}

# ECR
arn:aws:ecr:ap-northeast-1:{account_id}:repository/aip/{env}/preprocessor

# ECS
arn:aws:ecs:ap-northeast-1:{account_id}:cluster/aip-{env}-cluster
arn:aws:ecs:ap-northeast-1:{account_id}:task-definition/aip-{env}-preprocessor:N
arn:aws:ecs:ap-northeast-1:{account_id}:task/aip-{env}-cluster/*

# Lambda
arn:aws:lambda:ap-northeast-1:{account_id}:function:aip-{env}-invoke-bedrock
arn:aws:lambda:ap-northeast-1:{account_id}:function:aip-{env}-notify-chatwork

# DynamoDB
arn:aws:dynamodb:ap-northeast-1:{account_id}:table/aip-{env}-results
arn:aws:dynamodb:ap-northeast-1:{account_id}:table/aip-{env}-results/index/status-index

# Step Functions
arn:aws:states:ap-northeast-1:{account_id}:stateMachine:aip-{env}-inference-pipeline

# Bedrock（モデルはリージョン所有ではないため account_id 不要）
arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-3-haiku-20240307-v1:0

# IAM ロール
arn:aws:iam::{account_id}:role/aip-{env}-ecs-execution-role
arn:aws:iam::{account_id}:role/aip-{env}-ecs-task-role
arn:aws:iam::{account_id}:role/aip-{env}-lambda-bedrock-role
arn:aws:iam::{account_id}:role/aip-{env}-lambda-notify-role
arn:aws:iam::{account_id}:role/aip-{env}-sfn-role
arn:aws:iam::{account_id}:role/aip-{env}-eventbridge-role

# CloudWatch Logs
arn:aws:logs:ap-northeast-1:{account_id}:log-group:/aip/{env}/*

# SSM Parameter Store
arn:aws:ssm:ap-northeast-1:{account_id}:parameter/aip/{env}/chatwork/token
```

---

## ADR（アーキテクチャ決定記録）

設計判断の背景・理由・代替案の検討は以下のファイルに記録:

| ADR | タイトル | ファイル |
|---|---|---|
| 001 | なぜ Step Functions を使ったか | [docs/adr/001-use-step-functions.md](docs/adr/001-use-step-functions.md) |
| 002 | なぜ NAT Gateway でなく VPC Endpoint か | [docs/adr/002-vpc-endpoints-over-nat-gateway.md](docs/adr/002-vpc-endpoints-over-nat-gateway.md) |
| 003 | なぜ Bedrock モデルを Haiku にしたか | [docs/adr/003-bedrock-model-haiku.md](docs/adr/003-bedrock-model-haiku.md) |
