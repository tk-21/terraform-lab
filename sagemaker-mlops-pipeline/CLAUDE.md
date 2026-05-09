# CLAUDE.md - sagemaker-mlops-pipeline

## プロジェクト概要

SageMaker Pipelinesを使い、データ前処理→学習→評価→Model Registry登録→自動デプロイ→
Model Monitorによるドリフト検知までを一気通貫で自動化するMLOpsパイプライン基盤。
特定のモデルに依存しない汎用骨格として設計する。

## ディレクトリ構造

```
sagemaker-mlops-pipeline/
├── CLAUDE.md
├── README.md
├── ARCHITECTURE.md            # 設計本編
├── docs/
│   └── adr/                   # Architecture Decision Records
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── locals.tf
│   └── modules/
│       ├── foundation/        # S3, IAM, ECR, VPC endpoints
│       ├── pipeline/          # SageMaker Pipeline定義
│       ├── registry/          # Model Registry + 承認フロー
│       ├── endpoint/          # SageMaker Endpoint + CodePipeline
│       └── monitor/           # Model Monitor
├── pipeline/
│   ├── pipeline_definition.py # SageMaker Pipelines定義（Python SDK）
│   ├── steps/
│   │   ├── processing.py      # 前処理ステップ
│   │   ├── training.py        # 学習ステップ
│   │   ├── evaluation.py      # 評価ステップ
│   │   └── register.py        # Model Registry登録ステップ
│   └── scripts/
│       ├── preprocess.py      # Processing Jobスクリプト
│       ├── train.py           # Training Jobスクリプト
│       └── evaluate.py        # Evaluation Jobスクリプト
├── monitor/
│   ├── data_quality_baseline.py
│   └── model_quality_baseline.py
├── lambda/
│   ├── approval_notifier/     # Model Registry承認イベント → Chatwork通知
│   └── drift_handler/         # Model Monitor違反 → 再学習トリガー
├── .github/
│   └── workflows/
│       └── ci.yml             # OIDC認証、terraform validate + python lint
└── tests/
    ├── unit/
    └── integration/
```

## 命名規則

- プレフィックス: `smp` (sagemaker-mlops-pipeline)
- リソース例:
  - S3バケット: `smp-artifacts-{account_id}`, `smp-data-{account_id}`
  - ECRリポジトリ: `smp-processing`, `smp-training`
  - IAMロール: `smp-pipeline-role`, `smp-endpoint-role`
  - SageMaker Pipeline: `smp-training-pipeline`
  - Model Package Group: `smp-model-group`
  - SageMaker Endpoint: `smp-inference-endpoint`
  - CloudWatch Alarm: `smp-data-drift-alarm`, `smp-model-quality-alarm`

## Terraformルール

- バージョン: `>= 1.7`
- AWSプロバイダー: `>= 5.0`
- モジュール分割: foundation / pipeline / registry / endpoint / monitor
- ステート: ローカル（S3バックエンドはコメントで提示）
- `common_tags` locals必須:

```hcl
locals {
  common_tags = {
    Project     = "sagemaker-mlops-pipeline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
  }
}
```

## Pythonルール

- バージョン: `3.12`
- SageMaker SDK: `sagemaker>=2.200`
- Lambda: AWS Lambda Powertools（Logger/Tracer/Metrics必須）
- Lambdaアーキテクチャ: `arm64`
- 依存関係管理: `requirements.txt` per Lambda/script
- コメント: **日本語**で設計意図を記述

## SageMakerルール

- インスタンスタイプ:
  - Processing: `ml.m5.large`（コスト優先）
  - Training: `ml.m5.xlarge`
  - Endpoint: `ml.t2.medium`（テスト環境）、本番は `ml.m5.large`
- コンテナ: AWS提供のビルトインイメージを優先、カスタムは必要時のみ
- Model Registry: 承認ステータス `PendingApproval` でデフォルト登録
- Endpoint更新: Blue/Greenデプロイ（ダウンタイムゼロ）

## セキュリティルール

- SageMaker実行ロールは最小権限
- S3バケットはパブリックアクセスブロック有効
- VPC Endpointを使いインターネット経由のSageMaker通信を回避
- モデルアーティファクトはS3 SSE-S3暗号化
- ECRイメージスキャン有効化

## 通知ルール

- 通知先: **Chatwork**（Slackではない）
- API: `POST https://api.chatwork.com/v2/rooms/{room_id}/messages`
- ヘッダー: `X-ChatWorkToken`
- ボディ: `application/x-www-form-urlencoded` の `body` パラメータ
- room_idはSSM Parameter Storeから取得: `/smp/chatwork/room_id`
- 通知タイミング:
  1. モデル評価完了 → 承認依頼通知
  2. Data Drift検知 → アラート通知
  3. Model Quality劣化 → アラート + 再学習トリガー通知

## コストターゲット

- 月額上限: $15
- Endpointはテスト後に必ず停止（`aws sagemaker delete-endpoint`）
- Training Jobはスポットインスタンス使用（`use_spot_instances=True`）
- Model Monitorのスケジュール間隔: 1時間（最小課金単位）

## ドキュメントルール

- 各モジュールにREADME.md
- 設計判断はADRとして `docs/adr/` に記録
- アーキテクチャ図はMermaid形式
- Lambdaコード内コメントは日本語

## 禁止パターン

- ハードコードされたAWSアカウントID・クレデンシャル
- `AdministratorAccess` のIAMポリシー付与
- Endpointの常時起動（コスト超過防止）
- `us-east-1` へのリソース作成

## リージョン

`ap-northeast-1`（東京）固定
