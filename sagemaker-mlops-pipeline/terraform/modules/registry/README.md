# module: registry

Model Registryの承認フローと通知を管理する。

## 作成するリソース

| リソース | 名前 | 目的 |
|---|---|---|
| Lambda | `smp-approval-notifier` | PendingApproval/Approved → Chatwork通知 |
| EventBridge Rule | `smp-model-approval` | Model Package状態変化を検知 |
| EventBridge Rule | `smp-model-approved` | Approved → CodePipeline自動起動 |

## 承認フロー

```
Model Registry (PendingApproval)
  └─ EventBridge (smp-model-approval)
       └─ Lambda: approval_notifier → Chatwork通知

承認コマンド実行:
  aws sagemaker update-model-package --model-approval-status Approved

  └─ EventBridge (smp-model-approved)
       └─ CodePipeline (endpoint モジュール) → 自動デプロイ
```

## 依存関係

`endpoint` モジュールの `codepipeline_arn` と `eventbridge_codepipeline_role_arn` を参照するため、
`endpoint` モジュールより後に作成すること（main.tf でモジュール順を制御済み）。

## Inputs

| 変数 | 説明 |
|---|---|
| `prefix` | リソース名プレフィックス |
| `codepipeline_arn` | endpoint モジュールの CodePipeline ARN |
| `eventbridge_codepipeline_role_arn` | CodePipeline起動用EventBridgeロールARN |
| `powertools_layer_version` | Lambda Powertools レイヤーバージョン番号 |
