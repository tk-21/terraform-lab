# ADR-004: WAF ログに Kinesis Firehose を選んだ理由

**ステータス**: Accepted  
**日付**: <!-- 記述日を入れること -->

> **記述ルール**: 自分の言葉で記述すること。AI 生成テキストの貼り付け禁止。

---

## Context

<!-- TODO: WAF ログの保存先をどう設計するか検討した状況。
WAF v2 のログ出力先として何が選択肢にあったか（CloudWatch Logs / S3 / Firehose）。
ログをどのように活用したいかという目的も含めて書く。 -->

---

## Decision

<!-- TODO: Kinesis Firehose → S3 → Athena の構成を選んだ理由。一文で明確に。 -->

---

## WAF ログ出力先の仕様上の制約

<!-- TODO: AWS WAF v2 が CloudWatch Logs に「直接」ログを送れない理由。
（仕様: ログ出力先は Firehose / S3 / CloudWatch Logs だが、
CloudWatch Logs の場合もロールが必要で、実質 Firehose 経由が推奨される理由）
実際に試してみたこと・ハマったこと・公式ドキュメントで確認したことを書く。 -->

---

## Alternatives

### CloudWatch Logs Insights での分析

<!-- TODO: CloudWatch に直接送る構成を選ばなかった理由。
コスト・クエリのしやすさ・保存期間の観点で比較する。 -->

### S3 直接出力（Firehose なし）

<!-- TODO: WAF → S3 直接出力が選択肢にない理由（仕様上の制約）。
または、あるとしたら Firehose を介する理由は何か。 -->

---

## Firehose + S3 + Athena 構成の詳細

```
WAF → Kinesis Firehose (aws-waf-logs-*) → S3 (GZIP 圧縮)
                                              ↓
                                           Athena (Glue カタログ)
                                              ↓
                                           SQL クエリ分析
```

<!-- TODO: この構成を選んだことで得られたメリット（コスト・スケーラビリティ・クエリ柔軟性）。
実際に Athena でクエリを書いてみた感想も加えると良い。 -->

---

## Consequences

### コスト見積もり

| コンポーネント | 月額試算 | 条件 |
|---|---|---|
| Kinesis Firehose | <!-- TODO --> | GB 単位従量課金 |
| S3 ストレージ | <!-- TODO --> | GZIP 圧縮後のサイズ |
| Athena クエリ | <!-- TODO --> | 1 GB 上限設定で制限 |

### 運用上の注意点

<!-- TODO: Firehose のバッファリング設定（5MB or 5分）による遅延。
攻撃発生からログが S3 に届くまでのタイムラグ。
Athena パーティション設計（日付区切り）の重要性。 -->
