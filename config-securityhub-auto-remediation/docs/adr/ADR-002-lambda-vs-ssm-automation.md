# ADR-002: Lambda vs SSM Automation — 修復実行基盤の選定

## ステータス
決定済み

## コンテキスト
Config Rules違反を検知した後の自動修復実行基盤として、
AWS Lambda と AWS Systems Manager Automation Runbook のどちらを使うかを検討した。

## 検討した選択肢
- AWS Lambda (Python 3.12)
- AWS Systems Manager Automation Runbook
- AWS Config Remediation (SSM Automationの薄いラッパー)

## 決定
AWS Lambda (Python 3.12, arm64) を修復実行基盤として採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - Lambdaを選んだ具体的な理由(自由度、テスタビリティ、コスト等)
  - SSM Automationで対応できないケースがあるか
  - DLQとの組み合わせにおけるエラーハンドリングの柔軟性
-->

## 結果として生じるトレードオフ
- Lambdaはコードのメンテナンスが必要。SSM Automationはマネージドで管理コスト低。
- 複雑な修復ロジック（RDSスナップショット+通知の組み合わせ等）はLambdaが有利。
