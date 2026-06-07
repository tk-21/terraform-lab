# CLAUDE.md — aurora-rds-proxy-lab

## プロジェクト概要

Aurora Serverless v2 + RDS Proxy + Secrets Manager自動ローテーションのハンズオン。
ECS Fargate アプリケーションからRDS Proxyを経由してAurora PostgreSQLに接続し、
接続管理・パスワードローテーション・フェイルオーバーの運用設計を体得する。

### ポートフォリオ上の差別化ポイント
- DynamoDB(NoSQL)のみのポートフォリオに**RDB運用設計**を追加
- コンテナ × RDS Proxy という実務頻出構成の習得
- ゼロダウンタイムローテーション・フェイルオーバーの**定量的計測**

---

## アーキテクチャ概要

```
[ECS Fargate Task]
  └─ IAM Auth → [RDS Proxy]
                  ├─ Writer Endpoint → [Aurora Serverless v2 Writer]
                  └─ Reader Endpoint → [Aurora Serverless v2 Reader]

[Secrets Manager] ──自動ローテーション(7日)──▶ [Aurora ユーザー credentials]
[Lambda Rotator]  ──呼び出し──────────────────▶ [Secrets Manager]

[Chatwork] ◀── 通知 ── [EventBridge + Lambda]
```

---

## 共通制約（全フェーズ厳守）

### ネットワーク
- **NAT Gateway 禁止** — Private Subnet からの外部通信は VPC Endpoint のみ
- 必要な VPC Endpoint: `secretsmanager`, `ecr.api`, `ecr.dkr`, `logs`, `ssm`, `rds`
- リージョン: `ap-northeast-1` 固定

### コンピュート
- ECS: `FARGATE_SPOT` 優先（本番想定タスクのみ `FARGATE` 混在可）
- CPU アーキテクチャ: `arm64` (Graviton2)
- Lambda: Python 3.12 + Lambda Powertools、`arm64`

### IAM
- ワイルドカード (`*`) 禁止 — リソース ARN を明示
- OIDC 経由の GitHub Actions のみ（アクセスキー禁止）
- RDS Proxy への接続: IAM 認証（`rds-db:connect`）

### Terraform
- `terraform fmt` / `terraform validate` をフェーズ終了前に必ず実行
- `terraform.tfvars` に機密値を書かない（SSM / Secrets Manager 参照）
- State は S3 + DynamoDB Lock（Phase 1 で作成）

### Aurora / RDS
- Engine: `aurora-postgresql` (PostgreSQL 15)
- Aurora Serverless v2: `min_capacity = 0.5` ACU、`max_capacity = 4` ACU
- Multi-AZ: Writer 1台 + Reader 1台（`ap-northeast-1a` / `1c`）
- 削除保護: `deletion_protection = true`（Phase 6 の cleanup 時のみ一時解除）
- パラメータグループ: カスタム (`aurora-postgresql15`) を必ず作成

### RDS Proxy
- IAM 認証のみ（ユーザー/パスワード直接渡し禁止）
- `require_tls = true`
- Connection pooling: `connection_borrow_timeout = 120`

### Secrets Manager
- ローテーション間隔: 7日
- ローテーション Lambda: `SecretsManagerVPCEndpoint` 経由で呼び出し
- シークレット名プレフィックス: `arpl/` (aurora-rds-proxy-lab)

### アプリケーション (ECS Fargate)
- ベースイメージ: `python:3.12-slim` (arm64)
- DB ドライバ: `psycopg[binary]` (psycopg3)
- 接続文字列: 環境変数で渡さない → SSM Parameter Store の Proxy Endpoint のみ渡し、認証トークンはコード内で生成
- ヘルスチェック: `/health` エンドポイント (FastAPI)

### 通知
- 通知先: **Chatwork**（Slack 不可）
- API: `POST https://api.chatwork.com/v2/rooms/{room_id}/messages`
- ヘッダー: `X-ChatWorkToken`
- エンコード: `application/x-www-form-urlencoded`
- トークン保存先: SSM Parameter Store `/arpl/chatwork/token` (SecureString)

### コードスタイル
- Terraform: インラインコメントで設計根拠を日本語記述
- Python: docstring + インラインコメント日本語
- ハードコード禁止（接続情報・トークン・ARN はすべて変数/データソース参照）

---

## プロジェクトプレフィックス

`arpl` (aurora-rds-proxy-lab) — IAM ロール名64文字制限対応

---

## ディレクトリ構造

```
aurora-rds-proxy-lab/
├── CLAUDE.md
├── README.md
├── docs/
│   ├── architecture.md          # Mermaid アーキテクチャ図
│   ├── adr/
│   │   ├── 001-aurora-serverless-v2.md
│   │   ├── 002-rds-proxy-iam-auth.md
│   │   ├── 003-secrets-rotation-strategy.md
│   │   └── 004-vpc-endpoint-only.md
│   └── runbook/
│       ├── failover.md
│       └── rotation-verify.md
├── terraform/
│   ├── bootstrap/               # S3 state bucket + DynamoDB lock (Phase 1)
│   │   ├── main.tf
│   │   └── outputs.tf
│   ├── modules/
│   │   ├── networking/          # VPC, Subnet, VPC Endpoint, SG
│   │   ├── aurora/              # Cluster, Instance, Parameter Group, Subnet Group
│   │   ├── rds-proxy/           # Proxy, Target Group, IAM
│   │   ├── rotation/            # Secret, Rotation Lambda, Schedule
│   │   └── ecs-app/             # Task Def, Service, ALB, IAM
│   └── environments/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── terraform.tfvars # 機密値不可・リージョン/プレフィックスのみ
├── app/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── main.py                  # FastAPI エントリポイント
│   ├── db/
│   │   ├── connection.py        # RDS Proxy IAM Auth 接続管理
│   │   └── queries.py           # サンプルCRUD
│   └── api/
│       ├── health.py
│       └── items.py
├── lambda/
│   └── notifier/
│       ├── handler.py           # Chatwork通知 Lambda
│       └── requirements.txt
├── scripts/
│   ├── verify-rotation.sh       # ローテーション検証スクリプト
│   ├── failover-test.sh         # フェイルオーバーテスト
│   └── load-test.sh             # 接続プール確認用簡易負荷テスト
└── .github/
    └── workflows/
        └── deploy.yml           # OIDC GitHub Actions
```

---

## フェーズ一覧

| Phase | タイトル | 主要リソース |
|-------|---------|-------------|
| 1 | 基盤構築（VPC・Terraform State） | VPC, Subnet, VPC Endpoint, S3, DynamoDB |
| 2 | Aurora Serverless v2 構築 | Aurora Cluster, Instance, SG, Subnet Group |
| 3 | RDS Proxy + IAM 認証 | RDS Proxy, IAM Policy, Target Group |
| 4 | Secrets Manager ローテーション | Secret, Lambda Rotator, EventBridge通知 |
| 5 | ECS Fargate アプリ + ALB | FastAPI App, Task Def, Service, ALB |
| 6 | フェイルオーバー・ローテーション検証 | FIS / aws rds failover-db-cluster, 計測スクリプト |

---

## ADR 作成ルール

**ADR 本文（Contextを除くDecision・Consequencesセクション）は必ず自分の言葉で記述すること。**
AI生成テキストのコピーペースト禁止。面接での口頭説明の素材になるため。

---

## コスト目標

月額 $30 以下（dev環境・Aurora 最小ACU・FARGATE_SPOT前提）
- Aurora Serverless v2 (0.5 ACU idle): ~$0.06/ACU-hr
- RDS Proxy: インスタンスサイズ比例（db.t3.micro換算 ~$0.015/hr）
- NAT Gateway: $0（VPC Endpoint のみ）

---

## 口頭説明チェックポイント

各フェーズ完了後、以下を **自分の言葉で15分** 説明できること:

- Phase 2: Aurora Serverless v2 の ACU スケーリング仕組みと Provisioned との違い
- Phase 3: RDS Proxy が接続プールを管理するメカニズムとIAM認証フロー
- Phase 4: Secrets Manager ローテーションの Lambda 呼び出しシーケンス
- Phase 5: ECS タスクが RDS Proxy に接続するまでの IAM 認証トークン取得フロー
- Phase 6: フェイルオーバー時に RDS Proxy がどう振る舞うか（エンドポイント切替不要の理由）