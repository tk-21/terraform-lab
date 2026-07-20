# テスト結果記録

## 実施日
YYYY-MM-DD

## E2E テスト結果 (20件投入)
- 成功: X件 (X%)
- 在庫不足による失敗: X件
- 決済失敗によるリトライ後成功: X件
- DLQ 到達: X件

## パフォーマンス
- 平均 Step Functions 実行時間: X秒
- 決済処理 (ECS) 平均時間: X秒

## DLQ 動作確認
- DLQ 到達件数: X件
- 補償処理実行数: X件
- 補償処理成功率: X%

## 面接で話せるポイント
- [ ] SQS visibility_timeout の設定理由を説明できる
- [ ] Step Functions Retry の BackoffRate を使った理由を説明できる
- [ ] FARGATE_SPOT を選んだ根拠を説明できる
- [ ] DLQ の監視設計を説明できる
- [ ] 補償トランザクションと saga パターンの違いを説明できる
