# module: endpoint

SageMaker Endpoint と CodePipeline による自動デプロイを管理する。

## 作成するリソース

| リソース | 名前 | 目的 |
|---|---|---|
| SageMaker Endpoint | `smp-inference-endpoint` | リアルタイム推論エンドポイント |
| CodePipeline | `smp-deploy-pipeline` | 承認後の自動デプロイ |

## デプロイ戦略

Blue/Greenデプロイ（`ALL_AT_ONCE`）でダウンタイムゼロを実現。

```hcl
deployment_config {
  blue_green_update_policy {
    traffic_routing_configuration {
      type                     = "ALL_AT_ONCE"
      wait_interval_in_seconds = 300
    }
  }
}
```

## コスト注意

Endpointは使用後に必ず削除すること（月額コスト超過防止）：

```bash
aws sagemaker delete-endpoint --endpoint-name smp-inference-endpoint
```

## Inputs

| 変数 | 説明 |
|---|---|
| `prefix` | リソース名プレフィックス |
| `endpoint_role_arn` | foundation モジュールの `endpoint_role_arn` |
| `endpoint_instance_type` | 推論インスタンスタイプ（デフォルト: `ml.t2.medium`）|
| `endpoint_model_name` | デプロイするSageMakerモデル名（空文字でEndpoint未作成）|

## Outputs

| 出力 | 説明 |
|---|---|
| `codepipeline_arn` | registry モジュールが参照するCodePipeline ARN |
| `endpoint_name` | monitor モジュールが参照するEndpoint名 |
