# AWS Bedrock AI Platform Sandbox

## プロジェクト概要
エンタープライズ相当のAI基盤をAWS個人環境で再現する。
マルチテナント・セキュア・可観測・コスト制御を全て実装する。

## 技術スタック
- IaC: Terraform（モジュール化必須）
- クラウド: AWS ap-northeast-1
- 認証: OIDC（アクセスキー禁止）
- CI/CD: GitHub Actions
- 言語: Python 3.12（Lambda）

---

## ディレクトリ構成

```
bedrock-ai-platform-sandbox/        ← プロジェクトルート
├── CLAUDE.md                       ← このファイル（Claude Code用設計書）
├── README.md
├── .github/
│   └── workflows/
│       └── terraform.yml           ← OIDC認証 + plan/apply
├── environments/
│   └── dev/
│       ├── main.tf                 ← 全モジュールの呼び出し
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars
│       └── backend.tf              ← S3 remote state
└── modules/
    ├── networking/                 ← VPC・サブネット・VPCエンドポイント
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── bedrock-foundation/         ← IAMロール・Guardrails・CloudTrail
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── knowledge-base/             ← RAG基盤（S3 + Aurora pgvector）
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── bedrock-agent/              ← Agentリソース・Action Groups
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── schema/
    │       └── infra_ops.json      ← Action Group APIスキーマ
    ├── router-lambda/              ← インテリジェントルーター
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py
    ├── multi-tenant/               ← テナント管理（DynamoDB）
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── cost-controller/            ← トークン上限制御・アラート
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py
    ├── api-gateway/                ← WAF付きAPI Gateway
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    └── observability/              ← X-Ray・CloudWatch・コストアラート
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

---

## 設計原則

1. セキュリティ：VPCエンドポイント必須、最小権限IAM、アクセスキー禁止
2. コスト：月$30上限、テナントごとにトークン上限管理
3. 可観測性：X-Ray必須、CloudWatchダッシュボード
4. 再現性：全リソースTerraform管理、手動操作禁止

---

## タグ戦略（全リソース必須）

```hcl
tags = {
  Environment = "dev"
  Project     = "bedrock-ai-platform-sandbox"
  Owner       = "your-name"
  CostCenter  = "personal"
}
```

---

## モジュール間の依存関係

```
networking
  └──▶ bedrock-foundation
         ├──▶ knowledge-base
         └──▶ bedrock-agent
  └──▶ api-gateway
         └──▶ router-lambda
                └──▶ multi-tenant
                       └──▶ cost-controller

全モジュール ──▶ observability
```

---

## コスト最適化ルール

- Aurora Serverless v2 最小ACU: 0.5
- Lambda メモリ: 512MB以下
- OpenSearch Serverless: 使用禁止（pgvector代替）
- NAT Gateway: 1つのみ
- モデル選定：軽量タスクはHaiku、複雑タスクはSonnetを使い分ける

---

## 構築スケジュール

| Week | 対象モジュール |
|------|--------------|
| 1 | networking + bedrock-foundation |
| 2 | knowledge-base |
| 3 | router-lambda + multi-tenant |
| 4 | cost-controller + api-gateway |
| 5 | bedrock-agent |
| 6 | observability |
| 7 | GitHub Actions CI/CD |
| 8 | 統合テスト + Zenn記事化 |
