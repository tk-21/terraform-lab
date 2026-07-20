# ADR-002: Step Functions Retry / Catch 戦略

## Status
Accepted

## Context

注文処理パイプラインでは、Lambda・ECS・DynamoDB の各ステートで異なる種類の一時的障害が発生する可能性がある。

- **Lambda**: コールドスタート遅延、スロットリング (TooManyRequestsException)、SDK 接続エラー
- **ECS Fargate**: FARGATE_SPOT の突然の中断、コンテナ起動失敗、タスクタイムアウト
- **DynamoDB**: プロビジョニング超過 (オンデマンドでも高負荷時に一時的に発生)

これらはすべて一時的なエラーであり、即座に再試行すれば成功する可能性が高い。
一方で、決済処理は冪等性が求められるため、無制限のリトライは許容できない。

## Decision

全 Task ステートに Retry ブロックを設定し、以下のルールを適用する。

### Lambda ステート (CheckInventory / CompensatePayment / Notify*)
```
IntervalSeconds: 2, MaxAttempts: 3, BackoffRate: 2.0, JitterStrategy: FULL
```
- **JitterStrategy: FULL** を採用した理由: 複数の注文が同時にスロットリングされた場合、全注文が同じタイミングで再試行すると再度スロットリングが発生する（サンダーリングハード問題）。FULL ジッターにより再試行タイミングを分散させ、Lambda の同時実行数を平滑化する。

### ECS ステート (ProcessPayment)
```
IntervalSeconds: 5, MaxAttempts: 3, BackoffRate: 2.0
```
- Lambda より初回待機を長くした理由: Fargate タスクの起動自体に数秒かかるため、2秒待機では短すぎて効果がない。5秒を起点とすることで、Spot 中断後のタスク再スケジューリングに十分な時間を確保する。

### Catch (全ステート共通)
Retry を超えた場合は `HandleError` (DynamoDB に ERROR ステータスを書き込む) または `CompensatePayment` (決済失敗の補償処理) にルーティングする。

## Consequences

**保証されること:**
- 最大3回リトライにより、一時的な AWS サービス障害で注文が即座に失敗するケースを削減できる
- バックオフにより、障害中の AWS サービスへの過負荷を防げる

**前提条件:**
- 各 Lambda 関数は冪等性を持つ必要がある。特に `inventory-check` は「在庫を引き当て済みの場合は再引き当てしない」という処理が必要
- `ProcessPayment` (ECS) も同一 `order_id` に対して決済を重複実行しないよう、DynamoDB でべき等性チェックを実装すること

**監視:**
- Step Functions コンソールの「実行履歴」でリトライ回数を確認できる
- X-Ray トレースでどのステートでリトライが多発しているかを可視化し、根本原因を特定する
