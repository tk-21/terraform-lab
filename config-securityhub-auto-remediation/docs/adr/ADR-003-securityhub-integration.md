# ADR-003: Security Hub Custom Action の採用理由

## ステータス
決定済み

## コンテキスト
Config Rulesによる自動修復ループに加え、
セキュリティ担当者が「このFindingを今すぐ修復したい」と判断した場合の
手動トリガー修復フローが必要だった。

## 検討した選択肢
- Security Hub Custom Action (EventBridge経由でLambdaを直接起動)
- AWS Systems Manager Quick Setup
- Config Remediation (SSM Automation Runbook)
- AWS Lambda を直接マネジメントコンソールから手動実行

## 決定
Security Hub Custom Action を採用する。

## 決定理由
<!-- ⚠️ この欄はTakuya自身が記述してください。AI生成テキストの転用禁止 -->
<!-- 以下の観点を自分の言葉で説明してください:
  - なぜSecurity Hubのコンソールから直接修復操作できることがセキュリティ担当者にとって価値があるか
  - Config RuleトリガーとCustom Actionトリガーで同じLambdaを再利用できる利点
  - IAMコンソールやEC2コンソールに移動する必要がない運用上のメリット
-->

## 結果として生じるトレードオフ
- Security Hubの有効化コストが発生 (月$0.001/リソース記録)
- Findingのresource_type形式がConfig Ruleと異なるため変換ロジックが必要
  - Config Rule: `AWS::S3::Bucket`
  - Security Hub: `AwsS3Bucket`
