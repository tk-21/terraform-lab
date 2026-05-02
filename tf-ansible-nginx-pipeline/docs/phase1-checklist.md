# Phase 1 完了チェックリスト

## 設計思想の言語化
- [ ] TerraformとAnsibleの責務分界を自分の言葉で説明できる
- [ ] 「Immutable Infrastructure」と「Configuration Management」の違いを実例で説明できる
- [ ] terraform stateが「何を知っているか」を3点で説明できる

## 実装確認
- [ ] bootstrap/main.tfが構文エラーなく通る（terraform validate）
- [ ] S3バケットとDynamoDBテーブルが作成される（terraform apply）
- [ ] stateのバージョニングが有効になっている（AWSコンソールで確認）

## 深掘り質問（自己評価）
1. なぜDynamoDBのbilling_modeをPAY_PER_REQUESTにしたのか？
2. prevent_destroyをbootstrapだけに設定している理由は？
3. S3バケットの暗号化が必要な理由は何が保存されているから？
