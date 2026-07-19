# ADR-001: WAF スコープを CLOUDFRONT にした理由

**ステータス**: Accepted  
**日付**: <!-- 記述日を入れること -->

> **記述ルール**: 自分の言葉で記述すること。AI 生成テキストの貼り付け禁止。

---

## Context

<!-- TODO: なぜこの意思決定が必要だったか。どういう状況で選択を迫られたか。
例: ALB に直接 WAF (REGIONAL) をアタッチする構成と、CloudFront 経由で
CLOUDFRONT スコープの WAF をアタッチする構成、どちらにするか検討した。 -->

---

## Decision

<!-- TODO: 何を選んだか。一文で明確に。
例: WAF スコープは CLOUDFRONT を選択し、us-east-1 に WebACL を作成する。 -->

---

## Alternatives

### 検討した代替案: ALB への REGIONAL WAF

<!-- TODO: REGIONAL を選ばなかった理由。
- DDoS 緩和のタイミング（エッジ vs リージョン）の違い
- コスト（リクエスト処理費用の発生タイミング）
- グローバル配信との相性 -->

---

## Consequences

### メリット

<!-- TODO: CLOUDFRONT スコープにした良い点 -->

### トレードオフ・注意点

<!-- TODO: us-east-1 に WAF を置くことの運用上の注意点。
例: マルチリージョン展開時の複雑さ、CloudWatch メトリクスのリージョン、
Terraform の provider alias が必要になること -->
