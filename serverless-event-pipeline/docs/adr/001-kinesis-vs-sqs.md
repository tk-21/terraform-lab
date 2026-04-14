# ADR-001: Kinesis Data Streams vs SQS の選択基準

## ステータス

**Accepted** — 2024-01-15

---

## コンテキスト

イベント投入層のメッセージングサービスとして、Kinesis Data Streams と SQS のどちらを採用するかを検討する。

本システムには以下の 2 種類のイベント処理が存在する。

1. **リアルタイムストリーム処理**
   - API Gateway POST で受け付けたクリックストリーム・センサーデータ等
   - イベントの発生順序を保持したまま transformer Lambda が処理する必要がある
   - 同一ユーザー（`entity_id`）の複数イベントが順不同で処理されると集計値が不整合になる

2. **非同期バッチ処理**
   - S3 PUT で投入されたファイル単位のイベント
   - 各ファイルは独立して処理でき、処理順序に依存関係がない
   - DLQ を使ったリトライと失敗メッセージの保全が重要

当初は SQS FIFO キューで順序保証する案も検討したが、スループット上限（300 msg/s）とメッセージグループ ID による直列処理でスケーラビリティに課題があった。

---

## 決定

**用途によって Kinesis Data Streams と SQS を使い分ける**。

- **順序保証が必要なストリームデータ** → Kinesis Data Streams
- **独立したタスクの非同期処理** → SQS（DLQ 必須）

```
API Gateway POST → Kinesis Data Streams → transformer Lambda
                   （シャード内順序保証）

S3 PUT → SQS ingest-queue → ingestor Lambda → SQS DLQ（失敗時）
         （並列スケール・DLQ によるリトライ制御）
```

---

## 比較検討

| 観点 | Kinesis Data Streams | SQS 標準キュー | SQS FIFO キュー |
|---|---|---|---|
| 順序保証 | シャード内で保証 | 非保証 | グループ内で保証 |
| スループット | 1 MB/s 書込 / shard | ほぼ無制限 | 300 msg/s（上限あり） |
| メッセージ保持 | 最大 365 日 | 最大 14 日 | 最大 14 日 |
| 並列処理 | シャード数 × Lambda 同時実行 | ほぼ無制限 | グループ単位で直列 |
| コスト | シャード時間課金（~$15/shard/月） | メッセージ数課金 | メッセージ数課金（+20%） |
| Lambda ESM | シャードごとに並列 | batchSize 単位で並列 | MessageGroupId 単位で直列 |
| DLQ サポート | ESM の destination_config | 標準機能（redrive_policy） | 標準機能（redrive_policy） |
| 毒矢対策 | bisect_on_function_error | maxReceiveCount → DLQ | maxReceiveCount → DLQ |

---

## 決定理由

### Kinesis を選んだ理由

1. **シャード内順序保証**: `PartitionKey = entity_id` で同一ユーザーのイベントを同一シャードに割り当て、処理順序を保証する。SQS 標準キューではこれが保証できない。

2. **長期保持（最大 365 日）**: ストリームデータを長期間保持できるため、Lambda の障害から回復後に過去のデータを再処理できる。

3. **IteratorAge による遅延監視**: `GetRecords.IteratorAgeMilliseconds` メトリクスで処理遅延を定量的に監視できる。CloudWatch Alarm で `60,000 ms（60秒）` を閾値として設定。

4. **Enhanced Fan-Out**: 将来的に複数の Consumer（Lambda、Firehose、Flink）を追加できる拡張性。

### SQS を選んだ理由（ファイル単位処理）

1. **並列スケールの柔軟性**: 各 S3 ファイルは独立して処理できるため、並列処理数を自由に制御できる（`reserved_concurrent_executions` で流量制御）。

2. **DLQ の成熟した運用モデル**: `maxReceiveCount` と `redrive_policy` で失敗メッセージを自動的に DLQ へ移動できる。`ApproximateNumberOfMessages` アラームで即時検知。

3. **`batchItemFailures` による部分成功**: バッチ内の一部メッセージのみ失敗した場合、成功済みメッセージの再処理を防げる（Kinesis でも同様の機能あり）。

4. **コスト効率**: ファイル投入頻度が低い場合、Kinesis のシャード時間課金より SQS のメッセージ数課金が有利。

---

## 影響（トレードオフ）

### 採用することで得られるもの

- ストリームデータの順序保証により、集計値の整合性が保証される
- SQS の DLQ により、ファイル処理の失敗メッセージが消失しない
- 用途ごとに最適化された設計でコストとスケーラビリティのバランスが取れる

### 採用することで生じるコスト・複雑性

- Kinesis は `1 shard = ~$15/月` の固定コストが発生する。検証後は 1 shard まで削減して目標の月額 $5 以下を目指す。
- 2 種類のメッセージングサービスを管理するオペレーション負荷が増加する。
- Lambda ESM の設定が Kinesis と SQS で異なるため、モジュール（`kinesis-pipeline` / `sqs-pipeline`）を分けて管理する。

### 将来変更が必要になるケース

- イベント量が増加して 1 shard の容量（1 MB/s 書込）を超えた場合 → `shard_count` を増やす（コスト増）
- SQS のファイル処理が順序保証を必要とするようになった場合 → SQS FIFO に移行する（ただしスループット上限に注意）

---

## 参照

- [Amazon Kinesis Data Streams vs Amazon SQS — AWS 公式ガイド](https://docs.aws.amazon.com/streams/latest/dev/amazon-kinesis-data-streams-vs-sqs.html)
- [Lambda と Kinesis の ESM 設定](https://docs.aws.amazon.com/lambda/latest/dg/with-kinesis.html)
- [Lambda と SQS の ESM 設定（batchItemFailures）](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html)
- [ADR-003: エラーハンドリング戦略](003-error-handling-strategy.md)
