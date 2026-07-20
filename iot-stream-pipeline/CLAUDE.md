# CLAUDE.md — iot-stream-pipeline

## プロジェクト概要
IoTセンサー風データのリアルタイムストリーム処理パイプライン。
Kinesis → Lambda(コンテナ) → DynamoDB → API Gateway の構成をTerraformで構築する。

## アーキテクチャ
```
[センサーシミュレータ(Python)]
         ↓ PutRecord
[Kinesis Data Streams]
         ↓ イベントトリガー
[Lambda (ECRコンテナイメージ)]  ← DockerイメージをECRからPull
         ↓ PutItem
[DynamoDB (センサーデータテーブル)]
         ↓
[API Gateway (REST)] → GET /sensors/{device_id} → Lambda(読み取り用)
```

## ディレクトリ構成
```
iot-stream-pipeline/
├── CLAUDE.md
├── phase1.md       # 基盤インフラ (VPC不要, Kinesis/DynamoDB/ECR)
├── phase2.md       # Lambdaコンテナ (Dockerfile, ECRプッシュ, Kinesis連携)
├── phase3.md       # API Gateway + 読み取りLambda
├── phase4.md       # センサーシミュレータ + E2Eテスト + ADR
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── modules/
│       ├── kinesis/
│       ├── dynamodb/
│       ├── ecr/
│       ├── lambda/
│       └── apigateway/
├── lambda/
│   ├── processor/       # Kinesis→DynamoDB書き込みLambda
│   │   ├── Dockerfile
│   │   ├── app.py
│   │   └── requirements.txt
│   └── reader/          # API GW→DynamoDB読み取りLambda
│       ├── Dockerfile
│       ├── app.py
│       └── requirements.txt
├── simulator/
│   └── sensor_simulator.py
└── docs/
    └── adr/
        └── ADR-001-container-lambda.md
```

## 命名規則
- リソース名プレフィックス: `iot-pipeline`
- 例: `iot-pipeline-stream`, `iot-pipeline-table`, `iot-pipeline-processor`
- Terraformモジュール変数: `var.project_name = "iot-pipeline"`

## コスト制約 (厳守)
- NAT Gateway: **使用禁止** (月$32固定コスト)
- Lambda: arm64 (Graviton2) を使用
- Kinesis: オンデマンドモード (プロビジョニング不要)
- DynamoDB: PAY_PER_REQUEST (オンデマンド)
- ECR: イメージは最新1世代のみ保持 (lifecycle policy必須)
- テスト完了後は `terraform destroy` でリソース全削除

## コーディング規約
- Terraform: HCL形式、モジュール分割必須
- コメント: 日本語で「なぜそうするか」を記載 (「何をするか」ではない)
- Lambda: Python 3.12、arm64アーキテクチャ
- Dockerイメージ: `public.ecr.aws/lambda/python:3.12-arm64` をベースイメージに使用
- IAM: 最小権限原則 — 必要なアクションのみ許可、`*`リソース指定は極力避ける

## 禁止事項
- `iam:PassRole` を過剰に付与しない
- LambdaにAdminPolicyをアタッチしない
- ハードコードされたAWSアカウントIDをコードに埋め込まない (data.aws_caller_identity.currentを使用)
- 説明コメントなしのTerraformリソース定義

## フェーズ実行方法
```bash
claude < phase1.md
claude < phase2.md
claude < phase3.md
claude < phase4.md
```

## 口頭説明チェックポイント
各フェーズ完了後、以下を自分の言葉で15分説明できるか確認:
- Phase1: KinesisとDynamoDBのデータモデル設計の理由
- Phase2: LambdaコンテナとZIPデプロイの違いと選択理由
- Phase3: API GatewayのLambdaプロキシ統合の仕組み
- Phase4: ストリーム処理のエラーハンドリング戦略