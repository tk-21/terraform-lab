# module: foundation

S3・IAM・ECR・VPC Endpoint・SSMなど、全モジュールが依存する共通基盤リソースを管理する。

## 作成するリソース

| リソース | 名前 | 目的 |
|---|---|---|
| S3 Bucket | `smp-artifacts-{account_id}` | モデルアーティファクト・Pipeline中間成果物 |
| S3 Bucket | `smp-data-{account_id}` | 学習データ・テストデータ・ベースライン |
| IAM Role | `smp-pipeline-role` | SageMaker Pipeline実行ロール（最小権限）|
| IAM Role | `smp-endpoint-role` | SageMaker Endpoint実行ロール |
| IAM Role | `smp-lambda-base-role` | Lambda共通ベースロール（SSM・X-Ray） |
| ECR Repository | `smp-processing` | カスタムProcessingコンテナ用 |
| ECR Repository | `smp-training` | カスタムTrainingコンテナ用 |
| VPC Endpoint | SageMaker / S3 / ECR | インターネット経由のSageMaker通信を遮断 |
| SSM Parameter | `/smp/chatwork/*` | Chatwork API token・room_id |

## セキュリティ設計

- `AmazonSageMakerFullAccess` を使わず最小権限インラインポリシーを使用（ADR-002）
- S3バケットはパブリックアクセスブロック有効・SSE-S3暗号化
- VPC Endpointで通信をAWSネットワーク内に限定

## Inputs

| 変数 | 説明 |
|---|---|
| `prefix` | リソース名プレフィックス（`smp`）|
| `account_id` | AWSアカウントID |
| `region` | AWSリージョン |
| `common_tags` | 全リソースに付与する共通タグ |

## Outputs

| 出力 | 説明 |
|---|---|
| `artifacts_bucket_name` | アーティファクトS3バケット名 |
| `data_bucket_name` | データS3バケット名 |
| `pipeline_role_arn` | Pipeline実行ロールARN |
| `endpoint_role_arn` | Endpoint実行ロールARN |
| `lambda_base_role_arn` | Lambda基底ロールARN |
