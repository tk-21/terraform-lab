# module: pipeline

SageMaker Pipeline と Model Package Group を管理する。

## 作成するリソース

| リソース | 名前 | 目的 |
|---|---|---|
| SageMaker Pipeline | `smp-training-pipeline` | Processing→Training→Evaluation→Condition→Registerの一貫パイプライン |
| Model Package Group | `smp-model-group` | モデルバージョンの管理コンテナ |

## Pipeline定義の更新方法

Pipeline定義JSONはPython SDKで生成してからTerraformが参照する：

```bash
python pipeline/pipeline_definition.py \
  --action definition \
  --role-arn <ROLE_ARN> \
  --artifacts-bucket <BUCKET> \
  --data-bucket <DATA_BUCKET> \
  > terraform/modules/pipeline/pipeline_definition.json
```

## Inputs

| 変数 | 説明 |
|---|---|
| `prefix` | リソース名プレフィックス |
| `pipeline_role_arn` | foundation モジュールの `pipeline_role_arn` |
| `common_tags` | 共通タグ |

## Outputs

| 出力 | 説明 |
|---|---|
| `pipeline_name` | Pipeline名 |
| `pipeline_arn` | Pipeline ARN |
| `model_package_group_name` | Model Package Group名 |
