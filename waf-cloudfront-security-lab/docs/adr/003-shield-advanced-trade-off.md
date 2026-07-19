# ADR-003: Shield Advanced のコストトレードオフ

**ステータス**: Accepted  
**日付**: <!-- 記述日を入れること -->

> **記述ルール**: 自分の言葉で記述すること。AI 生成テキストの貼り付け禁止。

---

## Context

<!-- TODO: Shield Advanced（月額 $3,000〜）を検討する状況。
どのようなサービス規模・リスクプロファイルで検討するのか。
このラボでは Phase 4 のみ有効化して即削除した理由も含めて書く。 -->

---

## Decision

<!-- TODO: Shield Advanced を「フェーズ 4 のみ有効化・動作確認後即削除」とした理由。
本番採用するとしたらどういう条件のサービスか。 -->

---

## Shield Standard vs Advanced の具体的な差分

| 機能 | Standard | Advanced |
|---|---|---|
| 基本的な DDoS 緩和 | ✅ | ✅ |
| L7 DDoS 自動緩和 | ❌ | ✅ |
| DDoS コスト保護 | ❌ | ✅ |
| SRT（DDoS Response Team）サポート | ❌ | ✅ |
| 攻撃の可視化（CloudWatch） | 限定的 | 詳細 |
| WAF 使用料の無料化 | ❌ | ✅ |

<!-- TODO: 上記の差分のうち、自分のユースケースで最も価値があると思う機能はどれか。
なぜそれが重要か、自分の言葉で説明する。 -->

---

## Alternatives

### Shield Standard のみ継続

<!-- TODO: Standard だけで十分なケース。どういうサービスなら Advanced は不要か。 -->

### WAF + CloudFront で Shield Advanced を代替

<!-- TODO: Shield Advanced なしで DDoS 対策としてどこまでできるか。
CloudFront の帯域吸収・WAF レートリミットとの組み合わせ。 -->

---

## Consequences

<!-- TODO: Shield Advanced を採用しない場合に残るリスク。
採用する場合のコスト回収の考え方（DDoS コスト保護の条件など）。 -->
