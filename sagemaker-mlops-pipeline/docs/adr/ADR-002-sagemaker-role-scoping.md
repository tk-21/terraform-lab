# ADR-002: SageMaker実行ロールのAmazonSageMakerFullAccess一時採用

- **ステータス**: 採用済み（Phase 5で見直し予定）
- **日付**: 2026-04-30
- **決定者**: takuya

## コンテキスト

SageMaker Pipeline実行ロールに必要な権限を定義する際、初期段階では必要な権限の全容が把握できていない。最小権限原則に従い詳細なポリシーを即座に定義するか、広い権限で開始して段階的に絞り込むかの選択が必要。

## 決定

Phase 1では `AmazonSageMakerFullAccess` マネージドポリシーを使用する。Phase 5（セキュリティ強化フェーズ）で最小権限ポリシーへの置き換えを実施する。

## 理由

- 初期開発フェーズでは Processing / Training / Evaluation / Register の各ステップが実際にどの権限を要求するか、試行なしには確定できない
- 権限不足によるデプロイ失敗を繰り返すと開発速度が著しく低下する
- `AmazonSageMakerFullAccess` はSageMaker公式の推奨スターターポリシーであり、非本番環境での使用は許容範囲内

## リスクと緩和策

| リスク | 緩和策 |
|---|---|
| 過剰権限によるセキュリティリスク | 非本番環境（dev）限定での使用。本番化前に必ず絞り込む |
| 絞り込み作業の先送り | Phase 5のタスクとしてADRに明記し、忘却を防止 |
| 権限範囲の不明確さ | CloudTrailでの実際の呼び出しを記録し、Phase 5の絞り込みの根拠とする |

## Phase 5での対応計画

1. CloudTrailログから実際に呼び出されたAPIアクションを抽出
2. 必要最小限の権限のみを付与したカスタムポリシーを作成
3. `AmazonSageMakerFullAccess` を削除し、カスタムポリシーに置き換え
4. 本番環境への適用前に権限テストを実施

## 参照

- [AmazonSageMakerFullAccess Policy](https://docs.aws.amazon.com/sagemaker/latest/dg/security-iam-awsmanpol.html)
- AWS Security Best Practice: Least Privilege
