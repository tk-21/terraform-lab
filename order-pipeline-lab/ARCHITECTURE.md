# Order Pipeline Lab — アーキテクチャ完全理解ドキュメント

> ECサイト注文処理を模した、障害耐性重視の非同期処理パイプライン。
> 「なぜこの設計か」を口頭で説明できることをゴールとして設計。

---

## 目次

1. [システム全体図](#1-システム全体図)
2. [コンポーネント一覧](#2-コンポーネント一覧)
3. [ネットワーク構成](#3-ネットワーク構成)
4. [正常系フロー（ステップ詳解）](#4-正常系フローステップ詳解)
5. [障害系フロー](#5-障害系フロー)
6. [各コンポーネント詳細](#6-各コンポーネント詳細)
7. [データモデル（DynamoDB）](#7-データモデルdynamodb)
8. [IAM 権限設計](#8-iam-権限設計)
9. [可観測性（Observability）](#9-可観測性observability)
10. [コスト最適化](#10-コスト最適化)
11. [セキュリティ設計](#11-セキュリティ設計)
12. [設計判断まとめ（ADR 要約）](#12-設計判断まとめadr-要約)
13. [本番移行で追加すべき改善点](#13-本番移行で追加すべき改善点)

---

## 1. システム全体図

```
╔══════════════════════════════════════════════════════════════════════════╗
║                        VPC (10.0.0.0/16)                                ║
║                                                                          ║
║  クライアント                                                             ║
║  (aws sqs send-message)                                                  ║
║        │                                                                 ║
║        ▼                                                                 ║
║  ┌─────────────────────────┐    maxReceiveCount=3                        ║
║  │  SQS: orders-queue      │ ─────────────────────→ ┌─────────────────┐ ║
║  │  visibility: 300s       │                        │  SQS: orders-dlq│ ║
║  │  retention: 1日         │                        │  retention: 7日  │ ║
║  └────────────┬────────────┘                        └────────┬────────┘ ║
║               │ batch=1                                      │ batch=5  ║
║               ▼                                              ▼          ║
║  ┌─────────────────────────┐                   ┌─────────────────────┐  ║
║  │  Lambda: sfn-trigger    │                   │ Lambda: dlq-        │  ║
║  │  - SQS body をパース    │                   │ reprocessor         │  ║
║  │  - Step Functions 起動  │                   │ - 補償トランザクション│  ║
║  └────────────┬────────────┘                   │ - status=CANCELLED  │  ║
║               │ StartExecution                 └────────┬────────────┘  ║
║               ▼                                         │               ║
║  ┌─────────────────────────────────────────────────┐   │               ║
║  │          Step Functions State Machine            │   │               ║
║  │          (order-pipeline-order-sfn)              │   │               ║
║  │                                                  │   │               ║
║  │  ① Initialize ──────────────────────────────┐  │   │               ║
║  │     └─→ DynamoDB: status=RECEIVED            │  │   │               ║
║  │                                              │  │   │               ║
║  │  ② CheckInventory                            │  │   │               ║
║  │     └─→ Lambda: inventory-check             │  │   │               ║
║  │         └─→ status: INVENTORY_CHECKING      │  │   │               ║
║  │                      → INVENTORY_OK/FAILED  │  │   │               ║
║  │                                              │Catch│  │               ║
║  │  ③ IsInventoryOk (Choice)                   │→ HandleError         ║
║  │     ├─ OK  → ④ ProcessPayment              │  │   │               ║
║  │     └─ NG  → ⑥ NotifyFailure              │  │   │               ║
║  │                                              │  │   │               ║
║  │  ④ ProcessPayment (ECS RunTask.sync)        │  │   │               ║
║  │     └─→ ECS Fargate: payment-processor     │  │   │               ║
║  │         └─→ status: PAYMENT_PROCESSING     │  │   │               ║
║  │                      → PAYMENT_COMPLETED   │  │   │               ║
║  │                                              │  │   │               ║
║  │  ⑤ NotifySuccess ──────────────────────────┘  │   │               ║
║  │     └─→ Lambda: notification                   │   │               ║
║  │         └─→ status: COMPLETED                  │   │               ║
║  │                                                  │   │               ║
║  │  ⑥ NotifyFailure (在庫不足 / 決済失敗時)         │   │               ║
║  │     └─→ Lambda: notification                   │   │               ║
║  │         └─→ status: FAILED                     │   │               ║
║  └──────────────────────────────────────────────────┘   │               ║
║                    │                                      │               ║
║                    ▼                                      ▼               ║
║  ┌─────────────────────────────────────────────────────────────────────┐ ║
║  │                     DynamoDB: orders テーブル                        │ ║
║  │  PK: order_id  /  GSI: status-created_at-index                      │ ║
║  └─────────────────────────────────────────────────────────────────────┘ ║
║                                                                          ║
║  ┌──────────────┐   ┌───────────────┐   ┌────────────────────────────┐  ║
║  │ CloudWatch   │   │    X-Ray      │   │   VPC Endpoints (×9種)     │  ║
║  │ Dashboard    │   │   Service Map │   │   SQS / DynamoDB / ECR /   │  ║
║  │ Alarms (×3)  │   │               │   │   CloudWatch / SSM / 他    │  ║
║  └──────────────┘   └───────────────┘   └────────────────────────────┘  ║
╚══════════════════════════════════════════════════════════════════════════╝
```

---

## 2. コンポーネント一覧

| コンポーネント | サービス | 役割 |
|---|---|---|
| orders-queue | SQS | 注文メッセージの受信・バッファリング |
| orders-dlq | SQS | 3回失敗したメッセージの隔離 |
| sfn-trigger | Lambda | SQS を購読して Step Functions を起動 |
| order-sfn | Step Functions | 注文処理フローの全体オーケストレーション |
| inventory-check | Lambda | 在庫確認・予約処理 |
| payment-processor | ECS Fargate | 決済処理（Docker コンテナ） |
| notification | Lambda | 成功／失敗通知の送信 |
| dlq-reprocessor | Lambda | DLQ メッセージの補償処理 |
| orders | DynamoDB | 注文ステータスの永続化 |
| pipeline dashboard | CloudWatch | 全コンポーネントの監視 |

---

## 3. ネットワーク構成

### VPC・サブネット

```
┌─────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16  (ap-northeast-1)                        │
│  DNS: 有効 (VPC Endpoint 名前解決に必須)                    │
│                                                             │
│  ┌──────────────────────────┐  ┌──────────────────────────┐ │
│  │  Private Subnet A        │  │  Private Subnet C        │ │
│  │  10.0.1.0/24             │  │  10.0.2.0/24             │ │
│  │  ap-northeast-1a         │  │  ap-northeast-1c         │ │
│  │                          │  │                          │ │
│  │  ・Lambda (ENI)          │  │  ・Lambda (ENI)          │ │
│  │  ・ECS Fargate タスク    │  │  ・ECS Fargate タスク    │ │
│  └──────────────────────────┘  └──────────────────────────┘ │
│                                                             │
│  パブリックサブネット: なし                                   │
│  NAT Gateway: 禁止 (コスト削減)                             │
│  インターネットゲートウェイ: なし                             │
└─────────────────────────────────────────────────────────────┘
```

### VPC Endpoints（インターネット不要の理由）

```
プライベートサブネット内のリソース
        │
        │ HTTPS (port 443)
        ▼
┌───────────────────────────────────────────────────┐
│              VPC Endpoints                        │
│                                                   │
│  Interface 型 (ENI 経由):       Gateway 型 (無料): │
│  ┌────────────────────┐         ┌───────────────┐ │
│  │ com.amazonaws.*.sqs│         │  DynamoDB     │ │
│  │ com.amazonaws.*.ecr│         │  S3           │ │
│  │ .api / .dkr        │         │  (ECR レイヤー)│ │
│  │ com.amazonaws.*.logs│        └───────────────┘ │
│  │ com.amazonaws.*.ssm│                           │
│  │ com.amazonaws.*.sfn│                           │
│  │ com.amazonaws.*.xray│                          │
│  └────────────────────┘                           │
└───────────────────────────────────────────────────┘
        │
        ▼ AWS バックボーンネットワーク
   各 AWS サービス (SQS / DynamoDB / ECR ...)
```

**なぜ VPC Endpoints か**：NAT Gateway（~$45/月）を使わずに、AWS サービスと通信するため。
Interface 型は 1 ENI につき ~$0.01/h、Gateway 型は無料。

### セキュリティグループ

```
vpc_endpoints_sg:
  Inbound:  443/tcp  from 10.0.0.0/16 のみ
  Outbound: ALL

ecs_task_sg:
  Inbound:  なし (ECS タスクは呼ばれる側ではない)
  Outbound: 443/tcp → VPC Endpoints SG

lambda_sg:
  Inbound:  なし
  Outbound: 443/tcp → VPC Endpoints SG
```

---

## 4. 正常系フロー（ステップ詳解）

```
時系列で見る正常ケース (合計: 10〜30秒)

t=0s   クライアントが SQS へ注文投入
       Body: {"order_id": "ORD-001", "amount": 5000, "items": [...]}
           │
           ▼
t=1s   sfn-trigger Lambda が SQS をポーリング (batch=1)
       ・メッセージを JSON パース
       ・Step Functions の入力オブジェクトを構築
         (order_id / amount / items / 各リソース ARN を注入)
       ・states:StartExecution を呼び出し
       ・SQS メッセージを削除
           │
           ▼
t=2s   [Step Functions] ① Initialize
       ・dynamodb:PutItem
         {order_id: "ORD-001", status: "RECEIVED", amount: 5000, created_at: "..."}
           │
           ▼
t=3s   [Step Functions] ② CheckInventory
       ・lambda:invoke (inventory-check)
       ・Lambda 内処理:
         - DynamoDB: status → INVENTORY_CHECKING
         - 各 SKU の在庫を確認 (内部ロジック)
         - 在庫あり → reserved_items を返す
         - DynamoDB: status → INVENTORY_OK
       ・ResultPath: $.inventory_result に格納
           │
           ▼
t=5s   [Step Functions] ③ IsInventoryOk (Choice)
       ・$.inventory_result.inventory_ok == true → ProcessPayment へ
           │
           ▼
t=6s   [Step Functions] ④ ProcessPayment (ECS RunTask.sync)
       ・ecs:runTask で Fargate タスクを起動
         CPU: 256 / Memory: 512MB / ARM64 / Spot 80%
       ・.sync: ECS タスクが完了するまで Step Functions が待機
       ・コンテナ内処理 (payment-processor):
         - 環境変数: ORDER_ID / AMOUNT / RESERVED_ITEMS
         - DynamoDB: status → PAYMENT_PROCESSING
         - 決済 API 呼び出し (模擬)
         - DynamoDB: status → PAYMENT_COMPLETED, transaction_id を記録
       ・タスク終了 → Step Functions が次ステートへ進む
           │
           ▼
t=20s  [Step Functions] ⑤ NotifySuccess
       ・lambda:invoke (notification)
       ・Lambda 内処理:
         - DynamoDB: status → COMPLETED, completed_at を記録
         - (本番では SNS/メール等へ通知)
           │
           ▼
t=21s  OrderComplete (Succeed ステート)
       ・ステートマシン 正常終了
```

---

## 5. 障害系フロー

### 5-A: 在庫不足（inventory-check が NG を返す）

```
② CheckInventory
   └─→ inventory_ok = false (10% の確率でシミュレート)
         │
         ▼
③ IsInventoryOk: false → ⑥ NotifyFailure
   └─→ Lambda: notification
       └─→ DynamoDB: status → FAILED
           reason: "在庫不足: SKU=A001"
```

在庫予約が行われていないため、補償処理は不要。

---

### 5-B: 決済失敗 + リトライ（ECS タスクがエラー）

```
④ ProcessPayment (ECS RunTask.sync)
   └─→ ECS タスクが失敗 (exit code != 0)
         │
         ▼
   Retry (最大3回, IntervalSeconds=5, BackoffRate=2.0):
   ・1回目失敗 → 5秒待機 → 再試行
   ・2回目失敗 → 10秒待機 → 再試行
   ・3回目失敗 → Catch 発動
         │
         ▼
   Catch → CompensatePayment
   └─→ Lambda: notification (status=FAILED)
       └─→ DynamoDB: status → FAILED, failure_reason を記録
         │
         ▼
   ⑥ NotifyFailure → OrderFailed (Fail ステート)
```

---

### 5-C: SQS メッセージが 3回失敗 → DLQ

```
sfn-trigger Lambda がクラッシュ or order_id なし等でエラー
  │
  │ SQS は visibility timeout (300s) 後にメッセージを再可視化
  │
  ▼ 1回目の受信失敗
  │
  ▼ 2回目の受信失敗
  │
  ▼ 3回目の受信失敗 → maxReceiveCount 超過
  │
  ▼
SQS が自動的に orders-dlq へ転送 (AWS マネージド)
  │
  │ dlq-reprocessor Lambda が DLQ を購読 (batch=5, window=30s)
  ▼
  dlq-reprocessor:
  ・メッセージから order_id を抽出
  ・DynamoDB: status → CANCELLED_BY_DLQ
  ・compensated_at, dlq_receive_count を記録
  ・成功: SQS メッセージを削除
  ・失敗: batchItemFailures で返し、再処理 (ReportBatchItemFailures)
```

---

### 5-D: 予期しないエラー（全ステートの Catch）

```
全ステートに Catch ブロックが設定されている:

  Catch:
    ErrorEquals: [States.ALL]
    Next: HandleError

HandleError:
  ・dynamodb:UpdateItem
  ・status → ERROR
  ・error_detail に States.TaskFailed の詳細を JSON で記録
  │
  ▼
OrderFailed (Fail ステート)
```

---

### 障害シナリオまとめ

```
┌───────────────────────┬──────────────────────┬────────────────────────┐
│ 障害種別              │ 検知・対応            │ 最終 DynamoDB status   │
├───────────────────────┼──────────────────────┼────────────────────────┤
│ 在庫不足              │ inventory-check が NG │ FAILED                 │
│ 決済失敗 (1〜3回)    │ Retry (5s×3回)       │ (リトライで成功も有)   │
│ 決済失敗 (3回超過)    │ Catch → 補償処理     │ FAILED                 │
│ sfn-trigger クラッシュ│ SQS Redrive → DLQ   │ CANCELLED_BY_DLQ       │
│ 予期しないエラー      │ States.ALL Catch     │ ERROR                  │
└───────────────────────┴──────────────────────┴────────────────────────┘
```

---

## 6. 各コンポーネント詳細

### 6-1. SQS キュー設定

```
┌─────────────────────────────────────────────────────────┐
│  orders-queue                                           │
│                                                         │
│  visibility_timeout_seconds: 300                        │
│  ┗ なぜ: ECS Fargate コールドスタート (最大 5分) を考慮  │
│    処理中に他 Worker が同メッセージを受け取ることを防ぐ │
│                                                         │
│  message_retention_seconds: 86400 (1日)                 │
│  ┗ なぜ: 障害調査の猶予を確保                           │
│                                                         │
│  redrive_policy:                                        │
│    maxReceiveCount: 3                                   │
│    ┗ なぜ: 1〜2回は偶発エラー、3回で構造的障害と判断    │
│    deadLetterTargetArn: orders-dlq                      │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│  orders-dlq                                             │
│                                                         │
│  message_retention_seconds: 604800 (7日)                │
│  ┗ なぜ: 調査・手動再処理の猶予を長く確保               │
└─────────────────────────────────────────────────────────┘
```

### 6-2. Lambda 関数 詳細

#### sfn-trigger

```
┌──────────────────────────────────────────────────────────┐
│  order-pipeline-sfn-trigger                              │
│                                                          │
│  Runtime: Python 3.12 / ARM64 / VPC内                   │
│                                                          │
│  イベントソースマッピング:                                │
│    Source: orders-queue                                  │
│    BatchSize: 1  ← なぜ: 1注文=1実行で追跡容易          │
│                                                          │
│  処理:                                                   │
│    1. SQS body を JSON パース                            │
│    2. sfn_input 構築 (order_id / amount / items /        │
│       各リソース ARN を環境変数から注入)                  │
│    3. states:StartExecution 呼び出し                     │
│       実行名: "order-{order_id}" (重複防止)              │
└──────────────────────────────────────────────────────────┘
```

#### inventory-check

```
┌──────────────────────────────────────────────────────────┐
│  order-pipeline-inventory-check                          │
│                                                          │
│  Runtime: Python 3.12 / ARM64 / 256MB / 30s            │
│  Lambda Powertools: Logger + Tracer + Metrics           │
│                                                          │
│  処理:                                                   │
│    1. DynamoDB: status → INVENTORY_CHECKING             │
│    2. items リストの各 SKU を確認                        │
│    3. テスト用: 10% の確率で在庫切れシミュレート         │
│    4. 成功: reserved_items 返却, status → INVENTORY_OK  │
│    5. 失敗: reason 返却,  status → INVENTORY_FAILED     │
│                                                          │
│  カスタムメトリクス:                                      │
│    OrderPipeline/InventoryCheckSuccess                   │
│    OrderPipeline/InventoryShortage                       │
└──────────────────────────────────────────────────────────┘
```

#### notification

```
┌──────────────────────────────────────────────────────────┐
│  order-pipeline-notification                             │
│                                                          │
│  Runtime: Python 3.12 / ARM64 / 256MB / 30s            │
│                                                          │
│  処理:                                                   │
│    1. status: COMPLETED → completed_at 記録             │
│    2. status: FAILED    → failure_reason 記録           │
│    3. (本番: SNS / Chatwork / メール等へ通知)            │
│                                                          │
│  カスタムメトリクス:                                      │
│    OrderPipeline/NotificationSent                        │
└──────────────────────────────────────────────────────────┘
```

#### dlq-reprocessor

```
┌──────────────────────────────────────────────────────────┐
│  order-pipeline-dlq-reprocessor                          │
│                                                          │
│  Runtime: Python 3.12 / ARM64 / 256MB / 60s            │
│  ┗ タイムアウト長め: バッチ処理のため                    │
│                                                          │
│  イベントソースマッピング:                                │
│    Source: orders-dlq                                    │
│    BatchSize: 5                                          │
│    MaximumBatchingWindowInSeconds: 30                    │
│    FunctionResponseTypes: [ReportBatchItemFailures]      │
│    ┗ なぜ: バッチ内の一部失敗を個別報告 → 再処理可能     │
│                                                          │
│  処理:                                                   │
│    1. 各メッセージから order_id を抽出                   │
│    2. DynamoDB: status → CANCELLED_BY_DLQ               │
│       compensated_at / dlq_receive_count を記録          │
│    3. 失敗メッセージは batchItemFailures に積む          │
│                                                          │
│  カスタムメトリクス:                                      │
│    OrderPipeline/CompensationExecuted                    │
│    OrderPipeline/CompensationFailed                      │
└──────────────────────────────────────────────────────────┘
```

### 6-3. ECS Fargate (payment-processor)

```
┌──────────────────────────────────────────────────────────┐
│  Cluster: order-pipeline-cluster                         │
│                                                          │
│  Capacity Providers:                                     │
│    FARGATE_SPOT: weight=4 (80%)  ← コスト最大 70% 削減 │
│    FARGATE:      weight=1 (20%)  ← 中断時フォールバック  │
│                                                          │
│  Container Insights: 有効                                │
│    → CPU/Memory/Task 数がダッシュボードに自動表示        │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│  Task Definition: payment-processor                      │
│                                                          │
│  OS/Arch:  Linux / ARM64                                 │
│  CPU:      256 (0.25 vCPU)  ← IO 待ち中心で最小構成     │
│  Memory:   512 MB                                        │
│  Network:  awsvpc (ENI 専有)                             │
│  User:     appuser (非 root)                             │
│                                                          │
│  Environment Variables (Step Functions から注入):        │
│    ORDER_ID          ← $.order_id                       │
│    AMOUNT            ← $.amount                         │
│    RESERVED_ITEMS    ← $.inventory_result.reserved_items│
│    DYNAMODB_TABLE_NAME                                   │
│                                                          │
│  処理 (app.py):                                          │
│    1. DynamoDB: status → PAYMENT_PROCESSING             │
│    2. 決済 API 呼び出し模擬 (sleep + 乱数)              │
│    3. 成功: transaction_id 生成, status → PAYMENT_COMPLETED│
│    4. 失敗: exit(1) → Step Functions が Retry/Catch     │
└──────────────────────────────────────────────────────────┘
```

### 6-4. Step Functions ステートマシン

#### Retry 設定の比較

```
Lambda Retry:
  IntervalSeconds: 2
  MaxAttempts:     3
  BackoffRate:     2.0
  JitterStrategy:  FULL  ← 複数注文の同時スロットリング時に
                           再試行タイミングを無作為に分散
                           (サンダーリングハード対策)
  待機時間: 0〜2s → 0〜4s → 0〜8s (ランダム)

ECS Retry:
  IntervalSeconds: 5     ← Fargate 起動に 2〜3秒かかるため
  MaxAttempts:     3       Lambda より長め
  BackoffRate:     2.0
  待機時間: 5s → 10s → 20s
```

#### ステートマシン全フロー図

```
                  ┌─────────────┐
                  │  Initialize  │  DynamoDB PutItem
                  │  status=     │  (Retry × 3, Catch→HandleError)
                  │  RECEIVED    │
                  └──────┬───────┘
                         │
                  ┌──────▼───────┐
                  │ CheckInventory│  Lambda: inventory-check
                  │              │  (Retry × 3, Catch→HandleError)
                  └──────┬───────┘
                         │
                  ┌──────▼───────┐
                  │IsInventoryOk │  Choice
                  └──┬───────┬───┘
               true  │       │ false
                     │       ▼
                     │  ┌────────────┐
                     │  │NotifyFailure│  Lambda: notification
                     │  │status=FAILED│  (Retry × 3, Catch→HandleError)
                     │  └─────┬───────┘
                     │        │
              ┌──────▼──────┐ │
              │ProcessPayment│ │  ECS RunTask.sync
              │              │ │  (Retry × 3, Catch→CompensatePayment)
              └──┬───────┬───┘ │
        success  │       │ fail│
                 │       ▼     │
                 │  ┌──────────┴───┐
                 │  │CompensatePayment│  Lambda: notification (FAILED)
                 │  │  (補償処理)   │  (Retry × 3, Catch→HandleError)
                 │  └──────┬────────┘
                 │         │
                 │         ▼
                 │  ┌─────────────┐
                 │  │ NotifyFailure│
                 │  └──────┬──────┘
                 │         │
        ┌────────▼───┐     │
        │NotifySuccess│     │
        │status=      │     │
        │COMPLETED    │     │
        └──────┬──────┘     │
               │            │
        ┌──────▼──────┐ ┌──▼──────────┐
        │OrderComplete │ │ OrderFailed  │
        │  (Succeed)  │ │   (Fail)     │
        └─────────────┘ └──────────────┘

        ※ 全ステートからの Catch → HandleError:
            DynamoDB: status=ERROR, error_detail を記録
            → OrderFailed
```

---

## 7. データモデル（DynamoDB）

### テーブル設計

```
Table: order-pipeline-orders
  Billing: PAY_PER_REQUEST  (負荷不定のためオンデマンド)
  PITR:    有効              (本番移行時のデータ保護)

  PK: order_id (S)

  GSI: status-created_at-index
    PK: status (S)
    SK: created_at (S)
    Projection: ALL
    用途: ステータス別・日時順のクエリ
          例: 「直近1時間の FAILED 注文を取得」
```

### 注文ステータス遷移

```
                          ┌──────────────────┐
     sfn-trigger          │     RECEIVED      │  注文受付直後
     が DynamoDB を       └────────┬─────────┘
     直接書かず                    │ Initialize ステート
     Step Functions に             │
     委ねる設計                    ▼
                          ┌──────────────────┐
                          │INVENTORY_CHECKING │  inventory-check 処理中
                          └────────┬─────────┘
                           ┌───────┴────────┐
                           ▼                ▼
                  ┌──────────────┐  ┌─────────────────┐
                  │ INVENTORY_OK │  │ INVENTORY_FAILED │ → FAILED
                  └──────┬───────┘  └─────────────────┘
                         │
                         ▼
                  ┌──────────────────────┐
                  │ PAYMENT_PROCESSING   │  ECS タスク実行中
                  └──────┬──────────────┘
                   ┌─────┴──────┐
                   ▼            ▼
          ┌───────────────┐  ┌────────────────┐
          │PAYMENT_COMPLETED│  │ PAYMENT_FAILED │
          └───────┬────────┘  └───────┬────────┘
                  │                   │
                  ▼                   ▼
           ┌──────────┐         ┌──────────┐
           │COMPLETED │         │  FAILED  │
           └──────────┘         └──────────┘

  ※ DLQ 経由: CANCELLED_BY_DLQ (sfn-trigger 失敗時)
  ※ 予期しないエラー: ERROR
```

### アイテム例

```json
{
  "order_id":        "ORD-001",
  "status":          "COMPLETED",
  "amount":          5000,
  "items":           [{"sku": "X001", "qty": 2}],
  "reserved_items":  [{"sku": "X001", "qty": 2, "reserved": true}],
  "transaction_id":  "TXN-abc123",
  "paid_amount":     5000,
  "created_at":      "2024-01-20T10:00:00Z",
  "updated_at":      "2024-01-20T10:00:25Z",
  "completed_at":    "2024-01-20T10:00:25Z"
}
```

---

## 8. IAM 権限設計

### 最小権限の原則の適用

```
コンポーネントごとの独立したロール:

  sfn-trigger Lambda ─────→ sfn-trigger-lambda-role
    ・states:StartExecution (state machine ARN のみ)
    ・sqs:ReceiveMessage, DeleteMessage (orders-queue ARN のみ)

  inventory-check / notification / dlq-reprocessor
    Lambda ─────────────→ lambda-exec-role (共通)
    ・dynamodb: GetItem, UpdateItem, Query, PutItem
                (orders テーブル + GSI ARN のみ)
    ・sqs: ReceiveMessage, DeleteMessage (orders-dlq ARN のみ)
    ・ec2: CreateNetworkInterface (VPC 内実行のため)

  Step Functions ─────────→ sfn-role
    ・lambda:InvokeFunction (inventory-check, notification ARN のみ)
    ・ecs:RunTask, StopTask, DescribeTasks
    ・dynamodb:PutItem, UpdateItem (Initialize / HandleError 用)
    ・events:PutTargets, PutRule (.sync 統合のための EventBridge)

  ECS Task ───────────────→ ecs-task-role
    ・dynamodb:UpdateItem, GetItem (orders テーブルのみ)

  ECS Execution ──────────→ ecs-execution-role
    ・ecr:GetAuthorizationToken 等 (ECR pull 用)
    ・logs:CreateLogStream, PutLogEvents
```

---

## 9. 可観測性（Observability）

### 三本柱の実装

```
┌──────────────────────────────────────────────────────────┐
│ ① ログ (CloudWatch Logs)                                 │
│                                                          │
│  /aws/lambda/order-pipeline-inventory-check   保持: 7日  │
│  /aws/lambda/order-pipeline-notification      保持: 7日  │
│  /aws/lambda/order-pipeline-dlq-reprocessor   保持: 7日  │
│  /aws/lambda/order-pipeline-sfn-trigger       保持: 7日  │
│  /ecs/order-pipeline/payment-processor        保持: 7日  │
│  /aws/states/order-pipeline-order-sfn         保持: 7日  │
│                                                          │
│  フォーマット: JSON 構造化ログ (Lambda Powertools)        │
│  レベル: ALL (Step Functions は全遷移記録)               │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ ② メトリクス (CloudWatch Metrics)                        │
│                                                          │
│  AWS 標準:                                               │
│    AWS/States:  ExecutionsSucceeded, ExecutionsFailed,   │
│                 ExecutionTime                            │
│    AWS/Lambda:  Errors (関数別)                          │
│    AWS/SQS:     ApproximateNumberOfMessagesVisible,      │
│                 NumberOfMessagesSent                     │
│    ECS/ContainerInsights: TaskCount, RunningTaskCount    │
│                                                          │
│  カスタム (OrderPipeline namespace):                     │
│    InventoryCheckSuccess  在庫確認成功数                  │
│    InventoryShortage      在庫不足数                     │
│    NotificationSent       通知送信数                     │
│    CompensationExecuted   補償処理実行数                  │
│    CompensationFailed     補償処理失敗数                  │
└──────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────┐
│ ③ トレーシング (X-Ray)                                   │
│                                                          │
│  Lambda: @tracer.capture_lambda_handler デコレータ       │
│  ECS:    aws-xray-sdk (app.py 内で初期化)                │
│  Step Functions: tracing_configuration { enabled: true } │
│                                                          │
│  Service Map で見えるもの:                               │
│    sfn-trigger → Step Functions → inventory-check       │
│                               → payment-processor (ECS) │
│                               → notification            │
│                               → DynamoDB                │
└──────────────────────────────────────────────────────────┘
```

### CloudWatch ダッシュボード構成

```
┌─────────────────── order-pipeline-pipeline ─────────────────────┐
│ Row 1: Step Functions                                           │
│  [実行結果 (Succeeded/Failed/TimedOut)] [実行時間 Average (ms)] │
│                                                                 │
│ Row 2: SQS                                                      │
│  [キュー/DLQ メッセージ数 / Sent / Deleted (60s/Maximum)]      │
│                                                                 │
│ Row 3: Lambda                                                   │
│  [inventory / notification / dlq-reprocessor Errors (Sum)]     │
│                                                                 │
│ Row 4: ECS                                                      │
│  [TaskCount / RunningTaskCount (Container Insights)]           │
│                                                                 │
│ Row 5: 業務 KPI (カスタムメトリクス) ← 面接で「見ている指標」 │
│  [InventoryCheckSuccess / InventoryShortage /                  │
│   NotificationSent / CompensationExecuted / CompensationFailed]│
└─────────────────────────────────────────────────────────────────┘
```

### アラーム設定

```
┌───────────────────────────────────────────────────────┐
│ アラーム名                       閾値      検知間隔   │
├───────────────────────────────────────────────────────┤
│ order-pipeline-sfn-failures      > 3件     5分        │
│   └ Step Functions 実行失敗が多発したことを検知       │
│                                                       │
│ order-pipeline-inventory-check-errors > 5件  5分      │
│   └ 在庫確認 Lambda のエラー急増を検知               │
│                                                       │
│ order-pipeline-dlq-messages      > 0件     1分        │
│   └ DLQ に 1件でも届いたら即座に検知                 │
└───────────────────────────────────────────────────────┘
```

---

## 10. コスト最適化

### 施策と効果

```
┌─────────────────────────────────────────────────────────┐
│  施策                効果         実装箇所              │
├─────────────────────────────────────────────────────────┤
│  ARM64 (Graviton2)   −20%        Lambda, ECS            │
│  FARGATE_SPOT        最大−70%    ECS (80% Spot)         │
│  NAT Gateway 禁止    −$45/月     VPC Endpoint で代替    │
│  PAY_PER_REQUEST     柔軟課金    DynamoDB               │
│  ログ保持 7日         削減        全ロググループ         │
│  ECR 5世代制限        削減        ライフサイクルポリシー │
│  Gateway Endpoint    無料         DynamoDB, S3           │
└─────────────────────────────────────────────────────────┘

推定月額: ~$5 (テスト実行のみ・常時稼働なし)
```

### FARGATE_SPOT の中断耐性

```
Spot 中断 (最大 2分の警告あり)
  │
  ▼
ECS タスクが停止 → exit code != 0
  │
  ▼
Step Functions が Catch → CompensatePayment
  │
  ▼
Retry (IntervalSeconds=5, MaxAttempts=3)
  │
  ▼ 別の Spot インスタンスで再起動
payment-processor が再実行
  (べき等性: DynamoDB で transaction_id 重複チェック)
```

---

## 11. セキュリティ設計

```
層                   施策
─────────────────────────────────────────────────────────────
ネットワーク層       ・プライベートサブネットのみ
                     ・パブリック IP なし
                     ・NAT Gateway なし (インターネット通信なし)
                     ・VPC Endpoint 経由 (HTTPS / AWS バックボーン)
                     ・SG: 443/tcp のみ許可

認証・認可           ・IAM ロール最小権限 (コンポーネント別)
                     ・リソース ARN を明示指定 (ワイルドカード最小化)
                     ・ハードコード認証情報禁止

コンテナ             ・非 root ユーザー (appuser)
                     ・python:3.12-slim (最小イメージ)
                     ・ECR scan_on_push=true (脆弱性自動スキャン)

データ               ・DynamoDB デフォルト暗号化 (AWS 管理キー)
                     ・VPC Endpoint で通信暗号化 (TLS)
                     ・PITR 有効 (誤削除・腐敗データから復旧)

監査                 ・X-Ray: 全コンポーネントの分散トレーシング
                     ・CloudWatch Logs: 全操作を JSON 形式で記録
                     ・Step Functions: ALL ログレベル
                     ・タグ付け (Project / Environment / ManagedBy)
```

---

## 12. 設計判断まとめ（ADR 要約）

### ADR-001: visibility_timeout = 300秒

| 項目 | 内容 |
|---|---|
| 決定 | SQS visibility_timeout を 300秒に設定 |
| 理由 | ECS Fargate コールドスタート（最大5分）を考慮。処理中に他ワーカーが同メッセージを受け取ることを防ぐ |
| トレードオフ | クラッシュ時は最大 5分待機。3回失敗 × 300秒 = 最悪 15分宙ぶらりん |
| 詳細 | docs/adr/adr-001-sqs-visibility-timeout.md |

### ADR-002: Step Functions Retry 戦略

| 項目 | 内容 |
|---|---|
| 決定 | Lambda: BackoffRate=2.0, JitterStrategy=FULL。ECS: IntervalSeconds=5 |
| 理由 | JitterStrategy=FULL でサンダーリングハード（一斉再試行）を防ぐ。ECS は起動に 2〜3秒かかるため初回待機を長めに |
| 前提 | 各処理が冪等性を保証（同じ order_id を 2度処理しても結果が変わらない） |
| 詳細 | docs/adr/adr-002-step-functions-retry.md |

### ADR-003: DLQ + 補償トランザクション

| 項目 | 内容 |
|---|---|
| 決定 | SQS maxReceiveCount=3 で DLQ に転送。dlq-reprocessor で補償処理 |
| 理由 | Saga パターン: 分散トランザクションを「成功シーケンス + 補償処理」で実現。2PC (2相コミット) より耐障害性が高い |
| 補償処理の内容 | status=CANCELLED_BY_DLQ に更新（在庫予約は sfn-trigger 失敗なので未実施、解放不要） |
| 詳細 | docs/adr/adr-003-dlq-compensation.md |

---

## 13. 本番移行で追加すべき改善点

```
優先度 高:
  ① 通知実装
     現在: ログ出力のみ
     改善: SNS → Chatwork / メール / Slack

  ② visibility_timeout の実測チューニング
     現在: 300秒 (理論値)
     改善: 実際の ECS 実行時間を X-Ray で計測して調整

  ③ DynamoDB GSI クエリ最適化
     現在: テスト目的で scan を使用
     改善: GSI を使ったクエリのみに限定

優先度 中:
  ④ 決済 API の実装
     現在: 模擬 (sleep + 乱数)
     改善: 実際の決済 API (Stripe 等) に置き換え

  ⑤ ECS タスクサイズの見直し
     現在: CPU=256 / Memory=512 (最小構成)
     改善: 負荷テストで適切なサイズを決定

  ⑥ SQS 重複排除 / FIFO の検討
     現在: Standard キュー (at-least-once)
     改善: 同一 order_id の二重処理が問題になる場合は FIFO キュー

優先度 低:
  ⑦ Terraform S3 バックエンドへの移行
     現在: ローカル tfstate
     改善: S3 + DynamoDB でチーム共有・ロック

  ⑧ マルチリージョン対応
     現在: ap-northeast-1 のみ
     改善: DynamoDB Global Tables + Step Functions マルチリージョン

  ⑨ CloudWatch アラームへの SNS 通知追加
     現在: アラームのみ (通知先なし)
     改善: SNS Topic → Chatwork / PagerDuty 等
```

---

## 面接で話すポイント

```
Q: なぜ Step Functions を使ったか？
A: 複数ステップの順序制御・リトライ・エラーハンドリングをコードで書くと
   複雑になる。Step Functions で状態遷移を宣言的に定義し、
   各 Lambda を副作用のない単一責任関数に保てる。

Q: なぜ ECS を Lambda にしなかったか？
A: 決済処理は実行時間が不定で、外部 API 待ちが長い。
   Lambda の 15分制限とコールドスタートへの依存を避け、
   Docker で外部依存を完全に制御できる ECS を選択。

Q: DLQ はなぜ必要か？
A: 3回失敗したメッセージを隔離し、パイプライン全体が詰まることを防ぐ。
   7日間保持することで調査・手動再処理が可能。
   補償処理で注文を CANCELLED_BY_DLQ に更新し、状態不整合を防ぐ。

Q: Saga パターンと 2PC の違いは？
A: 2PC はすべての参加者をロックして原子性を保証するが、
   分散環境では可用性が低下する。Saga は各ステップを独立した
   トランザクションとし、失敗時は補償処理で整合性を回復する。
   障害耐性が高く、マイクロサービスに適している。

Q: コストをどう抑えているか？
A: NAT Gateway ($45/月) を VPC Endpoint に替え、
   ECS を FARGATE_SPOT (最大 70% 削減) で実行、
   Lambda と ECS を ARM64 (Graviton2, 約 20% 削減) に統一。
   DynamoDB はオンデマンド課金で低負荷時にコストゼロに近づける。
```
