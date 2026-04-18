# IAM Least Privilege Advisor

AWS IAM の過剰権限を自動検出し、Amazon Bedrock (Claude Sonnet) が最小権限ポリシーの修正案を Terraform PR として提案するシステムです。エンジニアは PR をレビュー・マージするだけで IAM の最小権限化を継続できます。

## アーキテクチャ

```
EventBridge Scheduler（毎週月曜 09:00 JST）
    |
    v
Lambda: analyzer-trigger
    |-- Access Analyzer (ACCOUNT_UNUSED_ACCESS) でスキャン実行
    |-- 未使用アクション Findings を S3 に保存
    |-- [非同期呼び出し]
    v
Lambda: policy-advisor
    |-- S3 から Findings 読み込み
    |-- IAM からマネージドポリシー取得
    |-- Bedrock (Claude Sonnet) で最小権限ポリシー生成
    |-- AI 出力検証（5項目チェック）
    |-- Terraform HCL 変換
    |-- GitHub PR 作成 ---------> GitHub リポジトリ
    |-- Chatwork 通知 ----------> Chatwork
    v
エンジニアが PR をレビュー・マージ
    |
    v
GitHub Actions (OIDC) --> terraform apply --> IAM ポリシー更新
```

**セキュリティ設計**: Lambda 実行ロールには `iam:PutPolicy` 系の権限を一切付与しません。ポリシー変更は PR マージを経由した Terraform Apply のみで行われます。

## 前提条件

- AWS CLI v2 がインストール・設定済みであること
- Terraform `~> 1.7` がインストール済みであること
- Python 3.12 がインストール済みであること
- 対象 AWS アカウントで **IAM Access Analyzer** が有効化されていること
- GitHub リポジトリに対して Contents / Pull Requests の書き込み権限を持つ Personal Access Token があること
- Chatwork API トークンがあること

## セットアップ手順

### 1. Secrets Manager にトークンを登録する

```bash
# GitHub Personal Access Token（repo スコープ必須）
aws secretsmanager create-secret \
  --name "iam-least-privilege-advisor/github-token" \
  --secret-string '{"token":"ghp_xxxxxxxxxxxxxxxxxxxx"}' \
  --region ap-northeast-1

# Chatwork API トークン
aws secretsmanager create-secret \
  --name "iam-least-privilege-advisor/chatwork-token" \
  --secret-string '{"api_token":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}' \
  --region ap-northeast-1
```

### 2. GitHub Actions 用 OIDC プロバイダーを設定する

AWS コンソール → IAM → ID プロバイダー → プロバイダーを追加

| 項目 | 値 |
|---|---|
| プロバイダーのタイプ | OpenID Connect |
| プロバイダー URL | `https://token.actions.githubusercontent.com` |
| 対象者 | `sts.amazonaws.com` |

次に、GitHub Actions が Assume Role するための IAM ロール（`github-actions-deploy-role` 等）を作成し、以下の信頼ポリシーを設定します。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:<OWNER>/<REPO>:*"
        }
      }
    }
  ]
}
```

### 3. GitHub Actions Secrets を設定する

リポジトリの Settings → Secrets and variables → Actions に以下を登録します。

| Secret 名 | 値 |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | OIDC ロールの ARN |
| `GITHUB_TOKEN_SECRET_ARN` | GitHub Token シークレットの ARN |
| `CHATWORK_SECRET_ARN` | Chatwork Token シークレットの ARN |
| `CHATWORK_ROOM_ID` | Chatwork 通知先ルーム ID |
| `GITHUB_OWNER` | GitHub オーナー名 |
| `GITHUB_REPO` | GitHub リポジトリ名 |

### 4. Terraform で AWS リソースをデプロイする

```bash
cd terraform

# terraform.tfvars を作成（terraform.tfvars.example を参考に）
cp terraform.tfvars.example terraform.tfvars
# 実際の値を編集する
vim terraform.tfvars

terraform init
terraform plan
terraform apply
```

## 動作確認方法

### EventBridge Scheduler を手動で実行する

```bash
# analyzer-trigger Lambda を直接 invoke してスキャンを手動実行する
aws lambda invoke \
  --function-name iam-least-privilege-advisor-analyzer-trigger \
  --invocation-type RequestResponse \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json \
  --region ap-northeast-1

cat /tmp/response.json
```

### S3 に保存された Findings を確認する

```bash
aws s3 ls s3://<BUCKET_NAME>/analyzer-results/ --recursive --region ap-northeast-1
aws s3 cp s3://<BUCKET_NAME>/analyzer-results/<YYYY>/<MM>/<DD>/findings.json - | jq .
```

### Lambda ログを確認する

```bash
# analyzer-trigger のログ
aws logs tail /aws/lambda/iam-least-privilege-advisor-analyzer-trigger \
  --follow --region ap-northeast-1

# policy-advisor のログ
aws logs tail /aws/lambda/iam-least-privilege-advisor-policy-advisor \
  --follow --region ap-northeast-1
```

## AI 出力のレビューポイント

PR がマージされると IAM ポリシーが変更されます。マージ前に以下を必ず確認してください。

### 確認すべき項目

1. **削除アクションの妥当性**
   - 削除されたアクションが本当に不要であることを確認する
   - 最終アクセス日が古くても、定期バッチ等で使用する可能性がないか確認する

2. **Resource の変更がないこと**
   - `Resource` 指定が元のポリシーから変更されていないことを確認する
   - AI 検証で自動チェックされるが、目視でも確認を推奨

3. **Condition の変更がないこと**
   - `Condition` ブロックが削除・変更されていないことを確認する

4. **Deny ルールの保持**
   - `Effect: Deny` の Statement が変更されていないことを確認する

5. **アプリケーションへの影響**
   - 削除対象のアクションがアプリケーションの起動パス・エラーハンドリング等で
     間接的に使用されていないか確認する

### 安全のために

- 本番環境は `staging` で先に確認してから `prod` にマージする運用を推奨
- 削除アクション数が多い PR は特に慎重にレビューする
- `warnings` セクションに「ポリシーが空になります」と記載された PR は
  ポリシー自体の削除を検討する

## コスト目安

月次コスト（東京リージョン、週 1 回実行・ロール 10 件想定）

| サービス | 月額目安 |
|---|---|
| Lambda（2 関数 × 週 4 回） | $0.00（無料枠内） |
| Bedrock（Claude Sonnet、約 10 回呼び出し） | $0.10〜$0.30 |
| S3（Findings JSON 保存、< 1MB/週） | $0.00（無料枠内） |
| CloudWatch Logs | $0.01〜 |
| **IAM Access Analyzer（未使用アクセス分析）** | **$0.20/ロール/月** |

> **注意**: IAM Access Analyzer の未使用アクセス分析（`ACCOUNT_UNUSED_ACCESS` タイプ）は分析対象のロール・ユーザー数に応じて課金されます（2025 年時点: $0.20/IAM ロールまたはユーザー/月）。ロール数が多いアカウントでは費用が増加します。

## 注意事項

### Access Analyzer の費用について

`ACCOUNT_UNUSED_ACCESS` タイプのアナライザーは IAM ロール・ユーザーの数に応じて**継続的に課金**されます。このシステムを使用しない期間や、コスト管理の観点から不要になった場合は、アナライザーを削除してください。

```bash
# アナライザーの一覧確認
aws accessanalyzer list-analyzers --region ap-northeast-1

# アナライザーの削除（課金停止）
aws accessanalyzer delete-analyzer \
  --analyzer-name iam-least-privilege-advisor-unused-access \
  --region ap-northeast-1
```

Terraform で削除する場合:

```bash
cd terraform
terraform destroy -target=module.access_analyzer
```

### Lambda のポリシー変更権限について

このシステムの Lambda 実行ロールには `iam:PutUserPolicy`・`iam:PutRolePolicy`・`iam:CreatePolicyVersion` 等のポリシー変更権限を**一切付与していません**。Lambda は IAM ポリシーを読み取り、GitHub PR を作成するのみです。実際のポリシー変更は PR マージ後の GitHub Actions (Terraform Apply) によってのみ行われます。
