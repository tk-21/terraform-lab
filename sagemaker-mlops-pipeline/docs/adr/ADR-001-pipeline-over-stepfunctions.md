# ADR-001: SageMaker PipelinesをStep Functionsより優先した理由

- **ステータス**: 採用済み
- **日付**: 2026-04-30
- **決定者**: takuya

## コンテキスト

MLOpsパイプラインのオーケストレーション基盤として、AWS Step FunctionsとAmazon SageMaker Pipelinesの2択で検討した。

## 決定

**Amazon SageMaker Pipelines** を採用する。

## 理由

- ML専用のステップタイプ（ProcessingStep / TrainingStep / RegisterModel / ConditionStep）が組み込みで提供されており、ボイラープレートなしにML workflowを記述できる
- 実験追跡・モデルリネージュ（入力データ→モデル→評価結果の系譜）がSageMaker Studio上でネイティブに可視化される
- Model Registryとの統合がシームレスで、RegisterModel Stepから直接モデルの登録・承認フローに接続できる
- AWS提供のビルトインコンテナとの親和性が高く、カスタムコンテナが不要なケースが多い

## トレードオフ

| 観点 | SageMaker Pipelines | Step Functions |
|---|---|---|
| ML特化機能 | ◎ ネイティブ対応 | △ カスタム実装が必要 |
| 汎用性 | △ MLタスクに限定 | ◎ 任意のAWSサービスと連携 |
| 実験追跡 | ◎ Studio統合 | × 別途実装が必要 |
| 学習曲線 | △ SageMaker SDK習得が必要 | ◎ 汎用的なJSON/YAMLで定義 |
| コスト | ◎ パイプライン実行自体は無料 | ○ ステート遷移ごとに課金 |

## 結論

Step Functionsはより汎用的だが、MLOpsに必要な機能（実験追跡、モデルリネージュ、Model Registry連携）の網羅性でSageMaker Pipelinesが優れる。本プロジェクトはML workflowの自動化が主目的であるため、SageMaker Pipelinesを選択する。
