# ADR-002: DynamoDB テーブル設計

## ステータス
承認済み

## コンテキスト
イベントデータのホットストレージとして DynamoDB を採用する。
アクセスパターンを事前に洗い出し、GSI 設計を確定する。

## 決定

### テーブル設計
```
テーブル: sep-<env>-events
  PK: entity_id (String)  例: USER#u123
  SK: event_ts  (String)  例: EVENT#2024-01-15T12:00:00Z
```

### GSI-1（status-index）
```
PK: status   (String)  PENDING / PROCESSED / FAILED
SK: event_ts (String)
```

### その他設定
- 課金モード: PAY_PER_REQUEST（オンデマンド）
- TTL: `expires_at`（30 日後自動削除）
- PITR: 有効（本番環境のみ）
- Streams: NEW_AND_OLD_IMAGES（aggregator Lambda のトリガー）

## アクセスパターン
1. `entity_id` によるイベント履歴取得 → PK クエリ
2. ステータス別のイベント一覧取得 → GSI-1 クエリ
3. 特定時間範囲のイベント取得 → SK の begins_with / between

## 影響
- 新しいアクセスパターンが発生した場合は GSI を追加する。
- GSI は最大 20 個まで作成可能。
