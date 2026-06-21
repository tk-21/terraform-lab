# アーキテクチャ概要

## 全体構成図

```
Internet
    │
    ▼
┌─────────────┐
│     ALB     │  (パブリックサブネット)
│  port: 80   │
└──────┬──────┘
       │
       ▼
┌─────────────────────────────────────────┐
│          Private Subnet                 │
│  ┌──────────────┐  ┌──────────────┐    │
│  │ ECS Task(Blue│  │ECS Task(Green│    │
│  │  port: 8080  │  │  port: 8080  │    │
│  └──────────────┘  └──────────────┘    │
│         │                              │
│  ┌──────▼───────────────────────────┐  │
│  │        VPC Endpoints             │  │
│  │  ECR API / ECR DKR / S3 / Logs   │  │
│  └──────────────────────────────────┘  │
└─────────────────────────────────────────┘

GitHub → CodePipeline → CodeBuild → ECR → CodeDeploy → ECS
```

## デプロイフロー

1. `git push origin main`
2. CodePipeline (Source ステージ) が GitHub から最新コードを取得
3. CodeBuild が `buildspec/buildspec.yml` を実行
   - docker buildx で arm64 イメージをビルド
   - ECR に `{commit_hash}` タグで push
   - `imagedefinitions.json` / `imageDetail.json` を生成
4. CodeDeploy が Blue/Green デプロイを実行
   - Green 環境に新タスクを起動
   - ALB テストリスナー (8080) でヘルスチェック
   - 本番トラフィック (80) を Green に切り替え
   - 5分後に Blue 環境のタスクを終了

## コスト設計

NAT Gateway を使わず VPC Endpoint で ECR/S3/Logs への通信を実現。
月額概算: ~$35 (ALB が支配的)

## セキュリティ設計

- ECS タスクはプライベートサブネット配置 (インターネットから直接アクセス不可)
- ALB SG → ECS タスク SG の参照でタスクへの直接アクセスを制限
- ECR イメージスキャン (push 時) を有効化
- IAM ロールは最小権限で設計
