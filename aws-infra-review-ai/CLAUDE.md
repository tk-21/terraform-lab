# aws-infra-review-ai

## プロジェクト概要

TerraformコードまたはAWSアーキテクチャ図を投入すると、
4つの専門AIエージェントが多角的にレビュー・議論し、
スーパーバイザーエージェントが統合した最終レポートを生成する
マルチエージェント型インフラレビュー基盤。

議論の過程（各エージェントの指摘・トレードオフ・統合判断）を
ログとして保存・可視化する。

---

## 技術スタック

| 項目 | 採用技術 |
|------|---------|
| IaC | Terraform（モジュール化必須） |
| クラウド | AWS ap-northeast-1 |
| 認証 | OIDC（アクセスキー禁止） |
| CI/CD | GitHub Actions |
| Lambda言語 | Python 3.12 |
| AIモデル | claude-3-5-sonnet（レビュー精度優先） |
| ワークフロー | Step Functions（Parallel State で並列議論） |
| 通知先 | Chatwork |

---

## ディレクトリ構成

```
aws-infra-review-ai/
├── CLAUDE.md                              ← このファイル（Claude Code用設計書）
├── README.md
├── .github/
│   └── workflows/
│       └── terraform.yml                  ← OIDC認証 + plan/apply
├── environments/
│   └── dev/
│       ├── main.tf                        ← 全モジュールの呼び出し
│       ├── variables.tf
│       ├── outputs.tf
│       ├── terraform.tfvars
│       └── backend.tf                     ← S3 remote state
└── modules/
    ├── storage/                           ← S3 + DynamoDB
    │   ├── main.tf                        ← レビュー入力・議論ログ保存
    │   ├── variables.tf
    │   └── outputs.tf
    ├── api/                               ← API Gateway（レビュー投入口）
    │   ├── main.tf
    │   ├── variables.tf
    │   └── outputs.tf
    ├── agents/
    │   ├── security-reviewer/             ← セキュリティ審査官エージェント
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   ├── outputs.tf
    │   │   └── src/
    │   │       └── index.py
    │   ├── cost-reviewer/                 ← コスト最適化エージェント
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   ├── outputs.tf
    │   │   └── src/
    │   │       └── index.py
    │   ├── reliability-reviewer/          ← 可用性・信頼性エージェント
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   ├── outputs.tf
    │   │   └── src/
    │   │       └── index.py
    │   ├── operations-reviewer/           ← 運用性エージェント
    │   │   ├── main.tf
    │   │   ├── variables.tf
    │   │   ├── outputs.tf
    │   │   └── src/
    │   │       └── index.py
    │   └── supervisor/                    ← スーパーバイザーエージェント
    │       ├── main.tf
    │       ├── variables.tf
    │       ├── outputs.tf
    │       └── src/
    │           └── index.py               ← 議論統合・矛盾解消・スコア算出
    ├── report-generator/                  ← HTMLレポート生成 + S3保存
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py
    ├── chatwork-notifier/                 ← Chatwork通知
    │   ├── main.tf
    │   ├── variables.tf
    │   ├── outputs.tf
    │   └── src/
    │       └── index.py
    └── workflow/                          ← Step Functions定義
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── definition.asl.json            ← ステートマシン定義
```

---

## エージェント構成と役割

| エージェント | チェック観点 |
|-------------|-------------|
| security-reviewer | IAM最小権限・暗号化・VPCエンドポイント・パブリック露出・Secrets管理・SGの過剰開放 |
| cost-reviewer | リソース過剰スペック・NAT Gateway数・Savings Plans適用可否・不要リソース |
| reliability-reviewer | Single AZ構成・バックアップ設定・フェイルオーバー・RPO/RTO |
| operations-reviewer | タグ戦略・監視設計・ログ出力・デプロイ戦略・ドリフト検知 |
| supervisor | 4エージェントの統合・矛盾解消・トレードオフ明示・総合スコア算出 |

---

## ワークフロー概要

```
ユーザー（TerraformコードまたはアーキテクチャPNG/PDFをS3にアップ）
  │
  ▼
API Gateway → Step Functions 起動
  │
  ├──▶ Parallel State（4エージェントが同時にレビュー）
  │     ├── security-reviewer
  │     ├── cost-reviewer
  │     ├── reliability-reviewer
  │     └── operations-reviewer
  │
  ├──▶ supervisor（議論統合・矛盾解消・トレードオフ明示）
  │
  ├──▶ report-generator（HTMLレポート生成 → S3保存）
  │
  └──▶ chatwork-notifier（サマリー + レポートリンク通知）
```

---

## 議論ログの構造（DynamoDB）

```
review_session
├── session_id         (PK)
├── input_type         # "terraform" or "architecture"
├── created_at
├── rounds
│   ├── round_1        # 各エージェントの初回レビュー
│   │   ├── security   { findings[], score, summary }
│   │   ├── cost       { findings[], score, summary }
│   │   ├── reliability{ findings[], score, summary }
│   │   └── operations { findings[], score, summary }
│   └── round_2        # スーパーバイザーの統合判断
│       ├── tradeoffs[]
│       ├── priority_actions[]
│       └── overall_score { security, cost, reliability, operations, total }
└── final_report_url   # S3のHTMLレポートURL
```

---

## 各エージェントの出力形式（JSON統一）

```json
{
  "agent": "security|cost|reliability|operations",
  "findings": [
    {
      "severity": "HIGH|MEDIUM|LOW",
      "resource": "リソース名",
      "issue": "問題の説明",
      "recommendation": "具体的な修正案"
    }
  ],
  "score": 0-100,
  "summary": "全体所見（2文以内）"
}
```

---

## 設計原則

1. **セキュリティ**：アクセスキー禁止、最小権限IAM（bedrock:InvokeModel のみ）
2. **議論の透明性**：全エージェントの発言をDynamoDBに記録し可視化
3. **トレードオフの明示**：スーパーバイザーが矛盾する指摘を整理して提示
4. **再現性**：全リソースTerraform管理、手動操作禁止
5. **学習目的**：コードにコメントを丁寧に入れる

---

## タグ戦略（全リソース必須）

```hcl
tags = {
  Environment = "dev"
  Project     = "aws-infra-review-ai"
  Owner       = "your-name"
  CostCenter  = "personal"
}
```

---

## コスト最適化ルール

- AIモデル: claude-3-5-sonnet（レビュー精度優先、ただしLambdaタイムアウトに注意）
- Lambda メモリ: 512MB以下、タイムアウト: 60秒
- DynamoDB: PAY_PER_REQUEST（検証環境のため）
- S3レポート: 90日で自動削除するライフサイクル設定

---

## モジュール間の依存関係

```
storage
  └──▶ agents/（全4エージェント + supervisor）
         └──▶ workflow（Step Functions）
                └──▶ report-generator
                       └──▶ chatwork-notifier

api ──▶ workflow（Step Functions起動トリガー）
```

---

## 構築スケジュール

| Week | 対象モジュール |
|------|--------------|
| 1 | storage + api + 4エージェントLambda（並列レビュー） |
| 2 | supervisor + workflow（Step Functions・議論フロー） |
| 3 | report-generator（HTML可視化）+ chatwork-notifier |
| 4 | アーキテクチャ図（画像）対応 + GitHub Actions CI/CD |
