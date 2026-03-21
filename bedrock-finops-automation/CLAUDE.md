# bedrock-finops-automation

## プロジェクト概要

AWS Cost ExplorerとAmazon Bedrock（Claude）を使って、
月次コストレポートを自動生成・Chatwork通知するFinOps自動化基盤。

コスト収集 → 異常検知 → AIレポート生成 → Chatwork通知 を
Step Functionsでオーケストレーションする。

---

## 技術スタック

| 項目 | 採用技術 |
|------|---------|
| IaC | Terraform（モジュール化必須） |
| クラウド | AWS ap-northeast-1（Cost ExplorerはUS-east-1固定） |
| 認証 | OIDC（アクセスキー禁止） |
| CI/CD | GitHub Actions |
| Lambda言語 | Python 3.12 |
| AIモデル | claude-3-haiku（コスト最適化） |
| ワークフロー | Step Functions |
| 通知先 | Chatwork |

---

## ディレクトリ構成

```
bedrock-finops-automation/
├── CLAUDE.md                          ← このファイル（Claude Code用設計書）
├── README.md
├── .github/
│   └── workflows/
│       └── terraform.yml              ← OIDC認証 + plan/apply
├── environments/
│   └── dev/
│       ├── main.tf                    ← 全モジュールの呼び出し
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars
│       └── backend.tf                 ← S3 remote state
└── modules/
    ├── storage/                       ← S3（レポート保存）+ DynamoDB（履歴管理）
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── collector/                     ← コストデータ収集Lambda
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py               ← Cost Explorer API
    ├── anomaly-detector/              ← 異常検知Lambda
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py               ← 前月比・スパイク判定
    ├── ai-reporter/                   ← AIレポート生成Lambda
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py               ← Bedrock（Claude Haiku）呼び出し
    ├── html-formatter/                ← HTMLレポート整形 + S3保存Lambda
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py
    ├── chatwork-notifier/             ← Chatwork通知Lambda
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py               ← Chatwork API呼び出し
    ├── workflow/                      ← Step Functions定義
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── definition.asl.json        ← ステートマシン定義
    └── scheduler/                     ← EventBridge定期実行
        ├── main.tf
        └── variables.tf
```

---

## ワークフロー概要

```
EventBridge（毎月1日 09:00 JST）
  │
  ▼
Step Functions
  │
  ├──▶ collector        : Cost Explorer APIでコストデータ収集
  ├──▶ anomaly-detector : 前月比・スパイク・サービス集中の異常検知
  ├──▶ ai-reporter      : Bedrock（Claude Haiku）でAI所見生成
  ├──▶ html-formatter   : HTMLレポート整形 → S3保存
  └──▶ chatwork-notifier: 要約 + S3リンクをChatworkに通知
```

---

## レポートに含める内容

1. 月次コスト合計・前月比較
2. サービス別コスト内訳（上位10件）
3. 異常検知・スパイクアラート

---

## 設計原則

1. **セキュリティ**：アクセスキー禁止、最小権限IAM、機密情報はSecrets Manager管理
2. **コスト**：AIモデルはHaikuを使用（レポート生成は軽量タスクのため）
3. **再現性**：全リソースTerraform管理、手動操作禁止
4. **学習目的**：コードにコメントを丁寧に入れる

---

## タグ戦略（全リソース必須）

```hcl
tags = {
  Environment = "dev"
  Project     = "bedrock-finops-automation"
  Owner       = "your-name"
  CostCenter  = "personal"
}
```

---

## 機密情報の管理

| 情報 | 管理場所 |
|------|---------|
| Chatwork APIトークン | Secrets Manager |
| ChatworkルームID | Systems Manager Parameter Store |

---

## コスト最適化ルール

- AIモデル: claude-3-haiku（Sonnet/Opusは使用禁止）
- Lambda メモリ: 512MB以下
- S3レポート: 90日でGlacierに移行するライフサイクル設定
- Cost ExplorerのAPIコール: 月数回以内に収める（1回$0.01）

---

## モジュール間の依存関係

```
storage
  └──▶ collector
         └──▶ anomaly-detector
                └──▶ ai-reporter
                       └──▶ html-formatter
                              └──▶ chatwork-notifier

全モジュール ──▶ workflow（Step Functions）
workflow    ──▶ scheduler（EventBridge）
```

---

## 構築スケジュール

| Week | 対象モジュール |
|------|--------------|
| 1 | storage + collector + anomaly-detector |
| 2 | ai-reporter + html-formatter + chatwork-notifier |
| 3 | workflow（Step Functions）+ scheduler（EventBridge）|
| 4 | GitHub Actions CI/CD + 統合テスト |