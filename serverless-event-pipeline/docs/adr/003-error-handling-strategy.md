# ADR-003: エラーハンドリング戦略

## ステータス
承認済み

## コンテキスト
Lambda のエラー処理とリトライ戦略を統一する。
イベントの消失ゼロを目標とする。

## 決定

### リトライフロー
```
処理失敗
  ↓
Lambda リトライ（最大 2 回、指数バックオフ）
  ↓ 全リトライ失敗
SQS DLQ へ移動
  MessageAttribute に失敗理由・試行回数を付与
  ↓ DLQ メッセージ数 >= 1
CloudWatch Alarm → SNS → Email
  ↓
dlq-handler Lambda が起動
  ↓
失敗理由を分類:
  - 一時エラー → 元キューに再エンキュー
  - 恒久エラー → S3 dead-letter-archive に保存
```

### 一時エラー vs 恒久エラーの分類基準

| エラー種別 | 例 | 対処 |
|---|---|---|
| 一時エラー | Throttling, タイムアウト, 接続エラー | 再エンキュー（指数バックオフ）|
| 恒久エラー | バリデーション失敗, 不正なデータ形式 | dead-letter-archive に保存 |

## 影響
- SQS DLQ なしの Lambda ESM は禁止（CLAUDE.md 参照）。
- 部分バッチ失敗は `batchItemFailures` で実装し、成功済みメッセージの再処理を防ぐ。
