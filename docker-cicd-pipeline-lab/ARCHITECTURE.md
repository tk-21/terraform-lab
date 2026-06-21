# ARCHITECTURE.md — docker-cicd-pipeline-lab 完全設計ドキュメント

---

## 目次

1. [システム概要](#1-システム概要)
2. [全体アーキテクチャ図](#2-全体アーキテクチャ図)
3. [CI/CD パイプラインフロー](#3-cicd-パイプラインフロー)
4. [Blue/Green デプロイの仕組み](#4-bluegreen-デプロイの仕組み)
5. [ネットワーク設計](#5-ネットワーク設計)
6. [各コンポーネント詳細](#6-各コンポーネント詳細)
7. [IAM 設計](#7-iam-設計)
8. [セキュリティ設計](#8-セキュリティ設計)
9. [可観測性設計](#9-可観測性設計)
10. [コスト設計](#10-コスト設計)
11. [Terraform モジュール構成](#11-terraform-モジュール構成)

---

## 1. システム概要

GitHub へのコード push を起点に、Docker イメージのビルド・ECR への登録・ECS Fargate への Blue/Green デプロイまでを **完全自動化** したフルマネージド CI/CD パイプライン。

### 使用技術スタック

| カテゴリ | サービス / ツール | 役割 |
|---|---|---|
| IaC | Terraform >= 1.6 | インフラ全体のコード管理 |
| ソース管理 | GitHub | アプリケーションコード |
| CI/CD 統合 | AWS CodePipeline | パイプライン制御 |
| ビルド | AWS CodeBuild | Docker イメージビルド・ECR push |
| コンテナレジストリ | Amazon ECR | プライベートイメージ管理 |
| コンテナ実行 | Amazon ECS Fargate (ARM64) | サーバーレスコンテナ実行 |
| デプロイ | AWS CodeDeploy | Blue/Green デプロイ制御 |
| ロードバランサー | Application Load Balancer | トラフィック制御・ヘルスチェック |
| ネットワーク | VPC + VPC Endpoint | プライベートネットワーク |
| 監視 | CloudWatch + EventBridge | メトリクス・アラーム・ダッシュボード |

---

## 2. 全体アーキテクチャ図

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                   AWS Cloud                                         │
│                                                                                     │
│  ┌──────────┐    ┌──────────────────────────────────────────────────────────────┐  │
│  │  GitHub  │    │                  CI/CD Pipeline                              │  │
│  │          │    │                                                              │  │
│  │  main    ├───▶│  ┌────────────┐   ┌────────────┐   ┌──────────────────────┐ │  │
│  │  branch  │    │  │CodePipeline│──▶│ CodeBuild  │──▶│   CodeDeploy         │ │  │
│  └──────────┘    │  │  (Source)  │   │  (Build)   │   │   (Blue/Green)       │ │  │
│                  │  └────────────┘   └─────┬──────┘   └──────────┬───────────┘ │  │
│                  └──────────────────────────┼──────────────────────┼────────────┘  │
│                                             │                      │               │
│                                             ▼                      │               │
│                                     ┌──────────────┐              │               │
│                                     │  Amazon ECR  │              │               │
│                                     │              │              │               │
│                                     │ :abc1234     │              │               │
│                                     │ :latest      │              │               │
│                                     └──────────────┘              │               │
│                                                                    │               │
│  ┌─────────────────────────────────────────────────────────────────┼───────────┐  │
│  │  VPC (10.0.0.0/16)                                              │           │  │
│  │                                                                 ▼           │  │
│  │  Public Subnet (10.0.0.0/24, 10.0.1.0/24)                                  │  │
│  │  ┌──────────────────────────────────────────────────────────────────────┐  │  │
│  │  │  Application Load Balancer (internet-facing)                         │  │  │
│  │  │                                                                      │  │  │
│  │  │  Listener :80  (本番)  ────── Forward ──▶ Blue TG / Green TG        │  │  │
│  │  │  Listener :8080 (テスト) ─── Forward ──▶ Green TG (動作確認用)      │  │  │
│  │  └──────────────────────────┬───────────────────────────────────────────┘  │  │
│  │                             │                                               │  │
│  │  Private Subnet (10.0.10.0/24, 10.0.11.0/24)                               │  │
│  │  ┌──────────────────────────┼───────────────────────────────────────────┐  │  │
│  │  │                          │  ECS Fargate (ARM64 / Graviton2)          │  │  │
│  │  │           ┌──────────────┴───────────────────┐                       │  │  │
│  │  │           │                                  │                       │  │  │
│  │  │  ┌────────▼───────┐             ┌────────────▼───────┐               │  │  │
│  │  │  │  Blue Task     │             │   Green Task        │               │  │  │
│  │  │  │  (旧バージョン) │             │   (新バージョン)    │               │  │  │
│  │  │  │  port: 8080    │             │   port: 8080        │               │  │  │
│  │  │  └────────────────┘             └────────────────────┘               │  │  │
│  │  │                                                                       │  │  │
│  │  │  ┌─────────────────────────────────────────────────────────────────┐ │  │  │
│  │  │  │  VPC Endpoints (NAT Gateway 不使用)                              │ │  │  │
│  │  │  │                                                                   │ │  │  │
│  │  │  │  [Gateway]  S3          ←── ECR イメージレイヤー (無料)           │ │  │  │
│  │  │  │  [Interface] ECR API   ←── イメージ manifest                     │ │  │  │
│  │  │  │  [Interface] ECR DKR   ←── Docker pull                           │ │  │  │
│  │  │  │  [Interface] CloudWatch Logs ←── コンテナログ送信                 │ │  │  │
│  │  │  └─────────────────────────────────────────────────────────────────┘ │  │  │
│  │  └───────────────────────────────────────────────────────────────────────┘  │  │
│  └─────────────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────────────┘

Internet
   │
   ▼ (HTTP :80)
  ALB
```

---

## 3. CI/CD パイプラインフロー

### シーケンス図

```
Developer        GitHub         CodePipeline      CodeBuild        ECR          CodeDeploy       ECS
    │               │                │                │              │                │             │
    │─── git push ─▶│                │                │              │                │             │
    │               │                │                │              │                │             │
    │               │──── webhook ──▶│                │              │                │             │
    │               │                │                │              │                │             │
    │               │         [Source Stage]          │              │                │             │
    │               │◀── checkout ───│                │              │                │             │
    │               │─── zip ───────▶│                │              │                │             │
    │               │          (S3 artifact store)    │              │                │             │
    │               │                │                │              │                │             │
    │               │          [Build Stage]          │              │                │             │
    │               │                │── StartBuild ─▶│              │                │             │
    │               │                │                │              │                │             │
    │               │                │          [Pre-build]          │                │             │
    │               │                │                │── ECR Login ▶│                │             │
    │               │                │                │◀─ token ─────│                │             │
    │               │                │                │              │                │             │
    │               │                │            [Build]            │                │             │
    │               │                │                │─ buildx ─────────────────────▶│             │
    │               │                │                │  (linux/arm64)                │             │
    │               │                │                │  :abc1234 + :latest           │             │
    │               │                │                │◀─ push完了 ──────────────────-│             │
    │               │                │                │              │                │             │
    │               │                │         [Post-build]          │                │             │
    │               │                │                │─ imagedefinitions.json 生成   │             │
    │               │                │                │─ imageDetail.json 生成        │             │
    │               │                │                │              │                │             │
    │               │          [Deploy Stage]         │              │                │             │
    │               │                │────────────────────────────── StartDeployment ▶│             │
    │               │                │                │              │                │             │
    │               │                │                │              │         [Green タスク起動]    │
    │               │                │                │              │                │── pull ────▶│
    │               │                │                │              │◀──────────────────────────── │
    │               │                │                │              │                │── 起動 ────▶│
    │               │                │                │              │                │             │
    │               │                │                │              │          [ヘルスチェック]     │
    │               │                │                │              │                │─ /health ──▶│
    │               │                │                │              │                │◀─ 200 OK ── │
    │               │                │                │              │                │             │
    │               │                │                │              │    [トラフィック切り替え]     │
    │               │                │                │              │     Port 80: Blue → Green    │
    │               │                │                │              │                │             │
    │               │                │                │              │  [5分後 Blue タスク削除]      │
    │               │                │                │              │                │             │
```

### 各フェーズの詳細

#### Stage 1: Source

```
GitHub push
    │
    ▼
CodeStarSourceConnection (OAuth)
    │
    ├── リポジトリをチェックアウト
    └── ZIP 圧縮 → S3 バケット (cicd-lab-prod-artifacts-{account_id})
                         └── source_output.zip
```

- **トリガー**: `DetectChanges = true` (ポーリング不要・push で即時起動)
- **ブランチ**: main

#### Stage 2: Build (buildspec.yml)

```
pre_build:
  ├── ECR ログイン
  │     aws ecr get-login-password | docker login
  └── IMAGE_TAG = CODEBUILD_RESOLVED_SOURCE_VERSION[0:8]
        例: "a3f8c21d"

build:
  ├── docker buildx create --use
  └── docker buildx build
        --platform linux/arm64    ← Graviton2 向け
        -t {ECR_URL}:a3f8c21d
        -t {ECR_URL}:latest
        ./app
        --push                    ← ビルドと同時に ECR へ push

post_build:
  ├── imagedefinitions.json 生成
  │     [{"name":"app","imageUri":"{ECR_URL}:a3f8c21d"}]
  │     ※ Rolling Update 用 (このラボでは参照のみ)
  └── imageDetail.json 生成
        {"ImageURI":"{ECR_URL}:a3f8c21d"}
        ※ CodeDeploy (Blue/Green) が IMAGE1_NAME を置換するために使用
```

#### Stage 3: Deploy (CodeDeploy)

CodePipeline が以下の2つのアーティファクトを CodeDeploy に渡す:

```
source_output (GitHub ソース)
  ├── terraform/task-definition.json   ← <IMAGE1_NAME> プレースホルダー入り
  └── appspec.yml                      ← <TASK_DEFINITION> プレースホルダー入り

build_output (CodeBuild 成果物)
  ├── imagedefinitions.json
  └── imageDetail.json                 ← {"ImageURI": "...url:a3f8c21d"}
```

CodeDeploy がプレースホルダーを実際の値に置換:

```
task-definition.json:  <IMAGE1_NAME>   → {ECR_URL}:a3f8c21d
appspec.yml:           <TASK_DEFINITION> → arn:aws:ecs:...:task-definition/cicd-lab-prod-app:42
```

---

## 4. Blue/Green デプロイの仕組み

### なぜ Blue/Green を選んだか

ECS のデフォルトの Rolling Update では、切り替え中に新旧バージョンのタスクが混在しトラフィックが分散してしまう。Blue/Green デプロイでは新バージョン (Green) でヘルスチェックを通過してから完全切り替えするため、ダウンタイムゼロが保証される。

### デプロイステート遷移

```
初期状態
─────────────────────────────────────────────────────────
  Internet
      │
      ▼ Port 80
     ALB
      │
      ▼
  [Blue TG] ──▶ Blue Task (v1: abc1234)
  [Green TG] ──▶ (空)

Step 1: Green タスク起動
─────────────────────────────────────────────────────────
  Internet
      │
      ▼ Port 80
     ALB
      │
      ├──▶ [Blue TG]  ──▶ Blue Task  (v1: abc1234)  ← 本番トラフィック継続
      │
      └──▶ [Green TG] ──▶ Green Task (v2: def5678)  ← 起動中

Step 2: ヘルスチェック & テストトラフィック
─────────────────────────────────────────────────────────
  Internet
      │
      ├──▶ Port 80  ──▶ ALB ──▶ [Blue TG]  ──▶ Blue Task  (v1)  ← 本番継続
      │
      └──▶ Port 8080 ──▶ ALB ──▶ [Green TG] ──▶ Green Task (v2)  ← /health 確認

Step 3: 本番トラフィック切り替え (action_on_timeout = CONTINUE_DEPLOYMENT)
─────────────────────────────────────────────────────────
  Internet
      │
      └──▶ Port 80 ──▶ ALB ──▶ [Green TG] ──▶ Green Task (v2)  ← 切り替え完了!
                                [Blue TG]  ──▶ Blue Task  (v1)  ← 5分間待機

Step 4: Blue タスク削除 (termination_wait_time_in_minutes = 5)
─────────────────────────────────────────────────────────
  Internet
      │
      └──▶ Port 80 ──▶ ALB ──▶ [Green TG] ──▶ Green Task (v2)  ← 安定稼働
                                (Blue Task は削除済み)
```

### ロールバック

デプロイ失敗時 (ヘルスチェック不通過) は CodeDeploy が自動でトラフィックを Blue に戻す。5分の猶予時間内であれば手動ロールバックも可能。

```
ロールバック発動条件:
  - /health が Unhealthy Threshold (3回) で失敗
  - CodeDeploy タイムアウト
  - 手動キャンセル

ロールバック後:
  Port 80 → Blue TG → Blue Task (旧バージョン) に戻る
```

---

## 5. ネットワーク設計

### VPC 構成

```
VPC: 10.0.0.0/16
│
├── ap-northeast-1a
│   ├── Public  Subnet: 10.0.0.0/24  (ALB 配置)
│   └── Private Subnet: 10.0.10.0/24 (ECS タスク配置)
│
└── ap-northeast-1c
    ├── Public  Subnet: 10.0.1.0/24  (ALB 配置)
    └── Private Subnet: 10.0.11.0/24 (ECS タスク配置)
```

### VPC Endpoint 設計 (NAT Gateway 不使用)

ECS タスクがプライベートサブネットから外部 AWS サービスに接続するための経路。NAT Gateway ($32/月) の代わりに VPC Endpoint を使用。

```
Private Subnet (ECS タスク)
       │
       │ HTTPS 443
       ▼
┌─────────────────────────────────────────────────────────┐
│  VPC Endpoints                                          │
│                                                         │
│  [Gateway]   S3 Endpoint                               │
│              └── 宛先: s3.ap-northeast-1.amazonaws.com  │
│              └── ECR イメージレイヤーのダウンロード        │
│              └── コスト: 無料 (Gateway 型)               │
│                                                         │
│  [Interface] ECR API Endpoint                           │
│              └── 宛先: api.ecr.ap-northeast-1.amazonaws.com │
│              └── イメージ manifest の取得                 │
│              └── コスト: ~$7.3/月 (Interface 型)         │
│                                                         │
│  [Interface] ECR Docker Endpoint                        │
│              └── 宛先: *.dkr.ecr.ap-northeast-1.amazonaws.com │
│              └── docker pull 実行                        │
│              └── コスト: ~$7.3/月 (Interface 型)         │
│                                                         │
│  [Interface] CloudWatch Logs Endpoint                   │
│              └── 宛先: logs.ap-northeast-1.amazonaws.com │
│              └── コンテナログの送信                       │
│              └── コスト: ~$7.3/月 (Interface 型)         │
└─────────────────────────────────────────────────────────┘
       │
       ▼ (VPC 内部のみ。インターネットには出ない)
   AWS サービス
```

> Interface 型 VPC Endpoint 合計: ~$22/月 vs NAT Gateway: ~$32/月+通信料

### セキュリティグループ

```
Internet ──▶ SG-ALB ──▶ SG-ECS-Task ──▶ SG-VPCE
              (Port 80)    (Port 8080)     (Port 443)

SG-ALB (ALB 用)
  Inbound:   0.0.0.0/0     → Port 80  (HTTP 公開)
  Outbound:  0.0.0.0/0     → All

SG-ECS-Task (ECS タスク用)
  Inbound:   SG-ALB        → Port 8080 (ALB からのみ)
  Outbound:  0.0.0.0/0     → All

SG-VPCE (VPC Endpoint 用)
  Inbound:   10.0.0.0/16   → Port 443  (VPC 内からのみ)
  Outbound:  0.0.0.0/0     → All

ポイント: ECS タスクは SG-ALB を送信元に指定しているため、
          ALB を経由しない直接アクセスは Port 8080 でも不可。
```

---

## 6. 各コンポーネント詳細

### Amazon ECR

```
リポジトリ名: cicd-lab-prod-app
リージョン:  ap-northeast-1

イメージタグ戦略:
  :abc1234    ← git commit SHA 先頭8文字 (必須)
  :latest     ← 最新ビルドの alias

ライフサイクルポリシー:
  最新10イメージを保持 → 11枚目以降を自動削除
  (ストレージコスト削減)

セキュリティ:
  scan_on_push = true → push 時に CVE スキャン自動実行
```

### Application Load Balancer

```
名前: cicd-lab-prod-alb
タイプ: internet-facing (外部公開)
配置: パブリックサブネット × 2 AZ

リスナー構成:
┌────────────────────────────────────────────────────────┐
│ Port 80  (本番)                                        │
│   Rule: Default → Forward to Blue TG                  │
│   ※ CodeDeploy が切り替え時に変更 (ignore_changes)     │
│                                                        │
│ Port 8080 (テスト用)                                   │
│   Rule: Default → Forward to Green TG                 │
│   ※ Green の動作確認に使用                             │
└────────────────────────────────────────────────────────┘

ターゲットグループ:
┌─────────────────────────────────────────────────────────┐
│ cicd-lab-prod-tg-blue  (Port 8080, Target Type: ip)    │
│   /health チェック: interval=30s, threshold 正常2/異常3  │
│                                                         │
│ cicd-lab-prod-tg-green (Port 8080, Target Type: ip)    │
│   /health チェック: 同上                               │
└─────────────────────────────────────────────────────────┘
```

### ECS Fargate

```
クラスター: cicd-lab-prod-cluster
  └── Container Insights: 有効
        └── CPU/Memory/Network メトリクスを CloudWatch に自動送信

タスク定義: cicd-lab-prod-app
  ┌──────────────────────────────────────────┐
  │ CPU:    256 (0.25 vCPU)                 │
  │ Memory: 512 MB                          │
  │ OS:     LINUX / ARM64 (Graviton2)       │
  │ Network: awsvpc                         │
  │                                         │
  │ コンテナ: app                           │
  │   Image:    {ECR_URL}:initial           │
  │             (→ CodeDeploy が上書き)     │
  │   Port:     8080/tcp                    │
  │   ENV:      PORT=8080                   │
  │             IMAGE_TAG=initial           │
  │   HealthCheck: GET /health              │
  │   Log:      /ecs/cicd-lab-prod/app      │
  └──────────────────────────────────────────┘

サービス: cicd-lab-prod-service
  desired_count: 1
  deployment_controller: CODE_DEPLOY
  network: プライベートサブネット, SG-ECS-Task
  assign_public_ip: false (VPC Endpoint 経由)
  lifecycle.ignore_changes: [task_definition, load_balancer]
    └── CodeDeploy が管理するため Terraform は干渉しない
```

### CodeBuild

```
プロジェクト名: cicd-lab-prod-build
環境:
  Image:          aws/codebuild/standard:7.0
  Compute Type:   BUILD_GENERAL1_SMALL
  Privileged Mode: true (Docker daemon 起動に必須)
  Timeout:        20分 (arm64 buildx はクロスコンパイルで遅め)

buildspec.yml フロー:
  pre_build  → ECR ログイン + コミット SHA 取得
  build      → docker buildx (linux/arm64) + ECR push
  post_build → imagedefinitions.json + imageDetail.json 生成

生成アーティファクト:
  imagedefinitions.json: [{"name":"app","imageUri":"..."}]
  imageDetail.json:      {"ImageURI":"..."}
```

### CodePipeline

```
パイプライン名: cicd-lab-prod-pipeline
アーティファクトストア: S3 (cicd-lab-prod-artifacts-{account_id})

ステージ:
  [Source] ─────── GitHub (main) ────────── source_output
      │
  [Build]  ─────── CodeBuild ──────────────  build_output
      │               └── source_output 入力
      │
  [Deploy] ─────── CodeDeployToECS ─────── (ECS へ反映)
                      ├── source_output (task-def + appspec)
                      └── build_output  (imageDetail)
```

### アプリケーション (app.py)

```python
# エンドポイント一覧
GET /health
  → 200 OK
  → {"status": "healthy"}

GET / (その他すべて)
  → 200 OK
  → {
       "message":   "Hello from ECS Fargate!",
       "image_tag": "{IMAGE_TAG}",     # 環境変数から取得
       "hostname":  "{container_id}",  # コンテナ ID
       "timestamp": "2026-01-01T..."   # ISO 8601
     }
```

---

## 7. IAM 設計

### ロール一覧と権限範囲

```
┌──────────────────────────────────────────────────────────────────────┐
│                         IAM ロール関係図                              │
│                                                                      │
│  CodePipeline ──── AssumeRole ──▶ cicd-lab-prod-pipeline-role        │
│                                       ├── S3 (artifacts bucket のみ) │
│                                       ├── CodeBuild (project のみ)   │
│                                       ├── CodeDeploy (app/dg のみ)   │
│                                       ├── ecs:RegisterTaskDefinition │
│                                       ├── iam:PassRole               │
│                                       │     └── task-exec-role       │
│                                       │     └── task-role            │
│                                       └── codestar-connections       │
│                                                                      │
│  CodeBuild ────── AssumeRole ──▶ cicd-lab-prod-codebuild-role        │
│                                       ├── ECR (repo ARN のみ)        │
│                                       ├── CloudWatch Logs            │
│                                       └── S3 (artifacts bucket のみ) │
│                                                                      │
│  CodeDeploy ───── AssumeRole ──▶ cicd-lab-prod-codedeploy-role       │
│                                       └── AWSCodeDeployRoleForECS    │
│                                             (ECS/ALB 操作権限)        │
│                                                                      │
│  ECS Task ──────── AssumeRole ──▶ cicd-lab-prod-ecs-task-exec-role   │
│  (起動時)                             └── AmazonECSTaskExecutionRolePolicy │
│                                             (ECR pull + Logs write)  │
│                                                                      │
│  ECS Task ──────── AssumeRole ──▶ cicd-lab-prod-ecs-task-role        │
│  (アプリ)                             └── (AWS サービス呼び出しに応じて追加) │
└──────────────────────────────────────────────────────────────────────┘
```

### 最小権限の実装ポイント

| アクション | スコープ | 理由 |
|---|---|---|
| `s3:GetObject/PutObject` | `artifacts_bucket_arn/*` のみ | 他バケットへのアクセスを禁止 |
| `codebuild:StartBuild` | `codebuild_project_arn` のみ | 別プロジェクトの実行を禁止 |
| `codedeploy:CreateDeployment` | App/DG ARN のみ | 別アプリへのデプロイを禁止 |
| `iam:PassRole` | `task_execution_role_arn` + `task_role_arn` のみ | 任意ロールの委譲を禁止 |
| `ecr:PutImage` | `ecr_repository_arn` のみ | 別リポジトリへの push を禁止 |
| `ecs:RegisterTaskDefinition` | `*` | AWS 仕様でリソース指定不可 ※ |
| `ecr:GetAuthorizationToken` | `*` | AWS 仕様でリソース指定不可 ※ |

※ AWS が `Resource: "*"` を必須とするアクションはコメントで明記している。

---

## 8. セキュリティ設計

### 多層防御

```
Layer 1: ネットワーク境界
  ・ECS タスクはプライベートサブネット (インターネットから直接到達不可)
  ・ALB のみがインターネットに面している (Port 80 のみ)
  ・assign_public_ip = false (ECS タスクに Public IP なし)

Layer 2: セキュリティグループ
  ・ECS タスク SG は ALB SG のみを送信元として許可
  ・VPC Endpoint SG は VPC CIDR (10.0.0.0/16) のみ許可
  ・タスクへの直接アクセスは ALB を経由しない限り不可

Layer 3: IAM 最小権限
  ・各コンポーネントは自分のタスクに必要な権限のみ付与
  ・ロール間の PassRole は明示的に許可されたロールのみ

Layer 4: コンテナセキュリティ
  ・非 root ユーザー (appuser) でプロセスを実行
  ・マルチステージビルドでビルドツールを最終イメージから除外
  ・ECR scan_on_push = true で CVE を早期検知

Layer 5: データ保護
  ・S3 アーティファクトバケットはパブリックアクセス完全ブロック
  ・S3 バージョニング有効 (アーティファクトの誤削除対策)
  ・VPC Endpoint でデータは AWS ネットワーク内を通過 (インターネット非経由)
```

### ハードコード禁止の徹底

```hcl
# ❌ 禁止
account_id = "123456789012"

# ✅ 採用
data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
}
```

---

## 9. 可観測性設計

### 監視全体像

```
┌─────────────────────────────────────────────────────────────────┐
│  CloudWatch Dashboard: cicd-lab-prod-overview                   │
│                                                                 │
│  ┌─────────────┐  ┌──────────────────┐  ┌───────────────────┐  │
│  │ ECS 実行    │  │ ALB HTTP         │  │ ALB レイテンシ    │  │
│  │ タスク数    │  │ レスポンスコード  │  │ p99               │  │
│  │ (avg/1min) │  │ 2xx/4xx/5xx sum  │  │                   │  │
│  └─────────────┘  └──────────────────┘  └───────────────────┘  │
│                                                                 │
│  ┌────────────────────────┐  ┌──────────────────────────────┐  │
│  │ CodeBuild ビルド時間   │  │ ECS CPU/Memory 使用率        │  │
│  │ (avg/5min, Succeeded)  │  │ (avg/1min, Container Insights│  │
│  └────────────────────────┘  └──────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### アラーム設定

| アラーム名 | 条件 | 意味 |
|---|---|---|
| `cicd-lab-prod-ecs-no-running-tasks` | RunningTaskCount < 1 | ECS タスクがゼロ = サービスダウン |
| `cicd-lab-prod-alb-high-5xx` | 5xx Count > 10 (2分間) | サーバーエラー急増 = デプロイ失敗の可能性 |

### EventBridge → CloudWatch Logs

```
CodePipeline 失敗イベント
    │
    ▼
EventBridge Rule (cicd-lab-prod-pipeline-failure)
    │ source: aws.codepipeline
    │ detail-type: CodePipeline Stage Execution State Change
    │ detail.state: FAILED
    │
    ▼
CloudWatch Logs (/aws/events/cicd-lab-prod/pipeline)
    └── 保持期間: 30 日
```

---

## 10. コスト設計

### 月額コスト内訳

| コンポーネント | スペック | 月額概算 |
|---|---|---|
| ECS Fargate (vCPU) | 0.25 vCPU × 730h × $0.04048 | ~$7.4 |
| ECS Fargate (Memory) | 0.5 GB × 730h × $0.004445 | ~$1.6 |
| ALB | 固定 + LCU | ~$16〜20 |
| ECR | ~1 GB ストレージ | ~$0.1 |
| CodeBuild | small, 従量課金 | ~$1 |
| S3 (Artifacts) | 標準 | ~$0.1 |
| VPC Endpoint (Interface×3) | $0.01/h × 3 × 730h | ~$22 |
| CloudWatch Logs | ログ量次第 | ~$1〜3 |
| **合計** | | **~$49〜55/月** |

> ALB と VPC Endpoint が支配的。ラボ環境なので使わないときは destroy 推奨。

### コスト削減施策

```
✅ NAT Gateway ($32+/月) を廃止 → VPC Endpoint に置き換え
   ただし Interface Endpoint 3本で $22/月 かかるため
   「NAT Gateway より少し安い」という理解が正確

✅ ARM64 (Graviton2) を採用
   → x86 比でコンピューティングコスト約 20% 削減

✅ ECR ライフサイクルポリシー
   → 最新 10 イメージのみ保持してストレージコスト抑制

✅ CloudWatch Logs 30 日保持
   → 長期保存は S3 Glacier への Export を推奨

✅ ALB アクセスログ無効
   → S3 へのログ書き込みコストを節約
```

---

## 11. Terraform モジュール構成

### モジュール依存関係

```
root (main.tf)
  │
  ├── module.networking   → VPC, Subnet, SG, VPC Endpoint
  │       └── outputs: vpc_id, subnet_ids, sg_ids
  │
  ├── module.ecr          → ECR リポジトリ
  │       └── outputs: repository_url, repository_arn
  │
  ├── module.alb          → ALB, TG (Blue/Green), Listener
  │       ├── inputs:  vpc_id ← networking
  │       └── outputs: tg_arns, listener_arns, alb_arn_suffix
  │
  ├── module.ecs          → Cluster, TaskDef, Service, IAM
  │       ├── inputs:  subnet_ids, sg_id  ← networking
  │       │            ecr_url            ← ecr
  │       │            tg_blue_arn        ← alb
  │       ├── depends_on: [module.alb]
  │       └── outputs: cluster_name, service_name, role_arns
  │
  ├── aws_s3_bucket.artifacts  (ルート直下で定義)
  │       └── codebuild と codepipeline の循環依存を避けるため
  │
  ├── module.codebuild    → CodeBuild Project, IAM
  │       ├── inputs:  ecr_url, ecr_arn  ← ecr
  │       │            artifact_bucket_arn ← root
  │       └── outputs: project_name, project_arn
  │
  ├── module.codepipeline → CodePipeline, CodeDeploy, IAM
  │       ├── inputs:  codebuild_project_name ← codebuild
  │       │            ecs_cluster/service    ← ecs
  │       │            listener_arns          ← alb
  │       │            role_arns              ← ecs
  │       │            artifact_bucket        ← root
  │       └── outputs: pipeline_name
  │
  └── module.observability → CloudWatch Alarm, Dashboard, EventBridge
          ├── inputs:  cluster_name, service_name ← ecs
          │            alb_arn_suffix              ← alb
          │            pipeline_name              ← codepipeline
          └── outputs: dashboard_url
```

### ファイル構成

```
docker-cicd-pipeline-lab/
├── ARCHITECTURE.md          # このファイル
├── README.md                # セットアップ手順
├── CLAUDE.md                # Claude Code 向けプロジェクト規約
├── appspec.yml              # CodeDeploy Blue/Green 設定
├── app/
│   ├── app.py               # Python HTTP サーバー
│   ├── Dockerfile           # マルチステージビルド (ARM64)
│   ├── requirements.txt
│   └── .dockerignore
├── buildspec/
│   └── buildspec.yml        # CodeBuild ビルド定義
├── scripts/
│   └── initial-push.sh      # 初回 ECR push スクリプト
├── docs/
│   ├── architecture.md      # 簡易アーキテクチャ概要
│   └── adr/                 # 設計判断記録 (Architecture Decision Records)
│       ├── 001-iac-tool.md
│       ├── 002-container-registry.md
│       ├── 003-deploy-strategy.md
│       └── 004-cost-design.md
└── terraform/
    ├── main.tf              # モジュール呼び出し・S3 バケット
    ├── variables.tf         # ルート変数定義
    ├── outputs.tf           # ルート出力
    ├── versions.tf          # プロバイダーバージョン固定
    ├── terraform.tfvars.example
    ├── task-definition.json # CodeDeploy 用タスク定義テンプレート
    └── modules/
        ├── networking/      # VPC, Subnet, SG, VPC Endpoint
        ├── ecr/             # ECR リポジトリ, ライフサイクル
        ├── alb/             # ALB, ターゲットグループ, リスナー
        ├── ecs/             # クラスター, タスク定義, サービス, IAM
        ├── codebuild/       # CodeBuild プロジェクト, IAM
        ├── codepipeline/    # CodePipeline, CodeDeploy, IAM
        └── observability/   # CloudWatch Alarm/Dashboard, EventBridge
```

---

## よくある疑問と回答

**Q: なぜ NAT Gateway を使わないのか？**

NAT Gateway は月額約 $32 + データ転送料がかかる。ECS が接続する先は ECR・S3・CloudWatch Logs の3サービスのみで、すべて VPC Endpoint に対応している。Interface 型 3本で $22/月 と NAT より安く、かつインターネットに出ないのでセキュリティも向上する。

**Q: なぜ `ecs:RegisterTaskDefinition` だけ `Resource: "*"` なのか？**

AWS の IAM ドキュメントで、このアクションはリソースレベル権限 (ARN 指定) が未サポートのため `*` が必須。他のアクション (`iam:PassRole`, `codedeploy:CreateDeployment` など) は適切な ARN に絞っている。

**Q: `privileged_mode = true` はなぜ必要か？**

CodeBuild の標準環境はコンテナで動作しており、その中で Docker daemon を動かして `docker build` を実行するには「コンテナ内コンテナ (DinD)」が必要になる。`privileged_mode = true` はそのホスト権限を有効にするフラグ。

**Q: `imageDetail.json` と `imagedefinitions.json` の違いは？**

- `imagedefinitions.json`: Rolling Update 用。`[{"name":"app","imageUri":"..."}]`
- `imageDetail.json`: Blue/Green (CodeDeploy) 用。`{"ImageURI":"..."}`

このラボは Blue/Green デプロイのため `imageDetail.json` が実際に使われる。

**Q: `lifecycle { ignore_changes = [task_definition, load_balancer] }` はなぜ必要か？**

CodeDeploy が Blue/Green デプロイのたびに ECS サービスの `task_definition` と `load_balancer` を書き換える。Terraform がそれを差分として検知して「元に戻そうとする」のを防ぐために ignore_changes で除外している。

**Q: `image_tag = "initial"` の意味は？**

`terraform apply` 時点では ECR にイメージが存在しないため、ブートストラップ用の固定値。その後 `initial-push.sh` を実行すると `:initial` タグのイメージが ECR に push される。以降の更新は CodePipeline/CodeDeploy が管理し、Terraform は `ignore_changes` でタスク定義に干渉しない。
