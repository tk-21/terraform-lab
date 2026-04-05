# ADR-001: DynamoDB Single Table Design の採用

- **ステータス**: 採用済み
- **決定日**: 2024-01-15
- **決定者**: platform-team

---

## 背景

DynamoDB のテーブル設計には大きく 2 つのアプローチがある。

1. **Multi Table Design**: RDB に近い設計。エンティティ種別ごとにテーブルを作成する
2. **Single Table Design**: すべてのエンティティを 1 テーブルに格納する DynamoDB ネイティブな設計

本プロジェクトでどちらを採用するかを検討した。

---

## 決定

**Single Table Design を採用する。**

---

## 採用理由

### 1. アクセスパターンが事前に確定している

DynamoDB は「書き込みスキーマ」ではなく「読み取りスキーマ」で設計する必要がある。
本プロジェクトのアクセスパターン（後述）はすべて設計段階で確定しており、
Single Table Design の前提条件を満たしている。

### 2. ホットパーティション回避

Multi Table Design では、アクセス頻度の高いエンティティに対するリクエストが
特定のパーティションに集中しやすい。Single Table Design では PK の設計により
自然なシャーディングが可能。

### 3. レイテンシ削減（JOIN ゼロ）

RDB では複数テーブルを JOIN するが、DynamoDB では JOIN が存在しない。
Single Table Design では 1 回の Query で複数エンティティを取得できる設計が可能。

### 4. コスト最適化

テーブルが 1 つのため、プロビジョニングリソースが分散しない。
PAY_PER_REQUEST モードとの組み合わせで、低トラフィック時のコストが最小になる。

---

## アクセスパターン一覧

| # | 操作 | アクセスパターン | 使用インデックス | クエリ方式 |
|---|---|---|---|---|
| AP-01 | アイテム作成 | `item_id` でアイテムを新規作成 | Primary Key | PutItem (ConditionExpression) |
| AP-02 | アイテム取得 | `item_id` でアイテムを1件取得 | Primary Key | GetItem |
| AP-03 | ユーザー別一覧 | `user_id` でアイテム一覧を作成日時降順取得 | GSI: user-index | Query (ScanIndexForward=False) |
| AP-04 | アイテム更新 | `item_id` でアイテムを更新 | Primary Key | UpdateItem |
| AP-05 | 論理削除 | `item_id` でアイテムを ARCHIVED に変更 | Primary Key | UpdateItem |
| AP-06 | ステータス別一覧 | `status` でアイテム一覧取得（管理用） | GSI: status-index | Query |
| AP-07 | TTL 自動削除 | `expires_at` 経過後に自動削除 | TTL 属性 | DynamoDB 自動処理 |

**注意**: フルスキャン（Scan API）は一切使用しない。すべてのアクセスパターンを
Primary Key または GSI を使った Query で実装する。

---

## テーブル設計

### Primary Key

```
PK: ITEM#<item_id>    (Hash Key)   例: ITEM#550e8400-e29b-41d4-a716-446655440000
SK: ITEM#<item_id>    (Range Key)  例: ITEM#550e8400-e29b-41d4-a716-446655440000
```

PK と SK を同じ値にする「自己参照」パターンを採用。
将来的に同一 PK に複数 SK を持つエンティティ（例: ITEM#xxx + COMMENT#yyy）を
追加できる余地を残している。

### GSI-1: user-index（AP-03 用）

```
PK: user_id      例: cognito-sub-abc123
SK: created_at   例: 2024-01-15T12:00:00+00:00
```

`ScanIndexForward=False` で作成日時の降順ソートを実現。
ページネーションは `ExclusiveStartKey` を Base64 エンコードした `cursor` で実装。

### GSI-2: status-index（AP-06 用）

```
PK: status      例: ACTIVE
SK: created_at  例: 2024-01-15T12:00:00+00:00
```

管理用途。`status=ACTIVE` のアイテムを日付順に取得したい場合に使用。

### TTL 設定

```
TTL 属性: expires_at（UNIX タイムスタンプ）
```

`status=ARCHIVED` に変更された時点で `expires_at = 現在時刻 + 30日` を設定する。
DynamoDB TTL が期限切れ後に物理削除する（通常 48 時間以内）。
TTL 削除は DynamoDB Streams に流れ、監査ログとして S3 に保存される。

---

## トレードオフ・注意点

### デメリット

| 項目 | 内容 |
|---|---|
| 設計難易度 | アクセスパターンを事前に確定しないと後から変更しにくい |
| 可読性 | PK/SK の命名規則を理解していないと読みにくい |
| 柔軟性 | 新しいアクセスパターンに対応するには GSI 追加が必要 |
| GSI 上限 | テーブルあたり最大 20 GSI（本設計では 2 つ使用） |

### 緩和策

- `PK` と `SK` の命名規則を CLAUDE.md に明記し、チーム全員が理解できるようにする
- 新しいアクセスパターンが発生した際は、このドキュメントを更新する

---

## 却下した代替案

### Multi Table Design

```
テーブル: users, items, comments, ...
```

**却下理由**:
- 本プロジェクトはエンティティ種別が少なく（現在は items のみ）、Multi Table のメリットが薄い
- PAY_PER_REQUEST の場合、テーブルを分けてもコスト面のメリットはない
- JOIN が不要な設計（GSI で完結）のため、Multi Table の利点である「テーブル単位の権限制御」も不要

---

## 参考

- [AWS DynamoDB Best Practices - Single Table Design](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/bp-general-nosql-design.html)
- [The What, Why, and When of Single-Table Design with DynamoDB](https://www.alexdebrie.com/posts/dynamodb-single-table/)
