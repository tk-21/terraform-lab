# ADR-001: AWS Config Rules vs GuardDuty — 検知手段の選定

## ステータス
決定済み

## コンテキスト
セキュリティコンプライアンス違反を自動検知・修復するにあたり、
AWS Config Rules と Amazon GuardDuty のどちらを主軸とするかを検討した。

## 検討した選択肢
- AWS Config Rules (マネージドルール + カスタムルール)
- Amazon GuardDuty
- AWS Security Hub (両者の統合層として)

## 決定
AWS Config Rules を主軸とし、Security Hub をFinding集約層として採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - なぜGuardDutyではなくConfig Rulesが今回の要件に合うのか
  - Config Rulesの評価タイミング（変更時/定期）がどう修復ループに影響するか
  - Security HubをFinding集約に使う理由
-->

## 結果として生じるトレードオフ
- Config Rulesは設定変更の検知が主目的。ランタイムの脅威検知はGuardDutyが得意。
- 今回はコンプライアンス違反の自動修復にフォーカスしており、Config Rulesが適切。
