# ADR-003: DLQ + 補償トランザクション設計

## Status
Accepted

## Context

注文処理パイプラインには2種類の「失敗」が存在する。

1. **Step Functions の Retry/Catch で吸収できる失敗**: 一時的な AWS サービス障害など。ADR-002 で対処済み。
2. **SQS レベルで吸収すべき失敗**: Lambda (sfn-trigger) 自体がクラッシュしたケース。この場合、Step Functions すら起動していないため、注文は SQS キューに残り続ける。

SQS では `maxReceiveCount` を超えたメッセージを自動的に DLQ (Dead Letter Queue) に転送できる。
DLQ に転送された注文は「システムが正常に処理できなかった注文」であり、単純な再投入では同じ原因で再び失敗する可能性が高い。

## Decision

### SQS パラメータ
- `maxReceiveCount: 3` — 3回の受信失敗で DLQ へ転送する。1-2回では偶発的エラーを捨てすぎる。4回以上では同一メッセージが長時間キューを占有し、後続メッセージの処理に影響する。
- `visibility_timeout: 300秒` — Step Functions の最大実行時間 (今回の設計では約3分) より十分長く設定し、実行中にメッセージが再送されることを防ぐ。
- DLQ `message_retention: 7日` — 障害調査と手動再処理に必要な猶予。

### 補償処理 (dlq-reprocessor Lambda)

DLQ に到達したメッセージに対して以下の補償処理を行う。

```
DLQ → dlq-reprocessor Lambda
  1. DynamoDB でその order_id の現在ステータスを確認
  2. ステータスが RECEIVED (Step Functions すら起動できなかった) の場合:
     → DynamoDB を FAILED に更新
     → （将来的に）顧客への通知を送信
  3. ステータスが COMPLETED または FAILED の場合:
     → すでに完結済みのため何もしない（重複メッセージの可能性）
```

「在庫の解放」は行わない。`inventory-check` が実行される前に失敗したケース (sfn-trigger が落ちた場合) は在庫予約自体が行われていないためである。在庫が予約済みの場合は Step Functions の CompensatePayment ステートが対処する。

## Consequences

**保証されること:**
- SQS レベルの障害 (Lambda クラッシュ・タイムアウト) で注文が消失しない
- 7日間の保持期間内であれば、手動での再投入・調査が可能
- DynamoDB に FAILED ステータスが記録されるため、注文の行方不明がなくなる

**前提条件 (冪等性):**
- dlq-reprocessor はべき等性を持つ必要がある。同一メッセージが2回処理されても、DynamoDB の最終状態が変わらないよう `ConditionExpression` で二重更新を防ぐこと。
- `ReportBatchItemFailures` を有効化することで、バッチ内の一部メッセージ処理失敗時に成功分を再処理せずに済む。

**限界:**
- 補償処理は「後始末」であり、完全なリカバリではない。顧客への自動通知・在庫の確実な整合は別途実装が必要。
- DLQ メッセージが増加した場合は根本原因 (sfn-trigger の Lambda エラー) の修正が先決。DLQ は緊急避難であってアーキテクチャの常用フローではない。

**監視:**
- CloudWatch で `ApproximateNumberOfMessagesVisible` (DLQ) にアラームを設定し、DLQ に積み上がった際に即座に検知できるようにする。
