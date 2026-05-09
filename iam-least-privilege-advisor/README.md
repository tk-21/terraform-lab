# IAM Least Privilege Advisor

AWS IAM の過剰権限を自動検出し、Amazon Bedrock (Claude Sonnet) が最小権限ポリシーの修正案を Terraform PR として提案するシステムです。エンジニアは PR をレビュー・マージするだけで IAM の最小権限化を継続できます。

## このハンズオンで得られること

この README の手順を最後まで進めると、次のことが理解できます。

- IAM Access Analyzer を使った未使用権限の継続検出の流れ
- Bedrock を使って IAM 最小権限化案を自動生成する仕組み
- Lambda から直接 IAM を変更せず、GitHub PR と Terraform で安全に反映する設計
- GitHub Actions OIDC を使った AWS への安全なデプロイ方法
- 実際に手を動かして、PR 作成と通知まで一連の動作を確認する方法

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

このハンズオンでは、次のものを使います。

- AWS CLI v2
- Terraform `~> 1.7`
- Python 3.12
- GitHub リポジトリ
- GitHub Personal Access Token
- Chatwork API トークン

必要な権限のイメージ:

- Terraform 実行用の AWS 権限
  - IAM ロール / ポリシー作成
  - Lambda 作成
  - EventBridge Scheduler 作成
  - S3 バケット作成
  - Access Analyzer 作成
  - Secrets Manager 参照
- GitHub 側の権限
  - PR 作成先リポジトリに対する `Contents: write`
  - PR 作成先リポジトリに対する `Pull requests: write`

## ハンズオン実行手順

以下の順で進めると、最短で「AWS にデプロイして、手動実行で PR が作られるところまで」確認できます。

### 0. このハンズオンで作るもの

作業が終わると、次の流れが動くようになります。

1. EventBridge Scheduler が `analyzer-trigger` Lambda を週次起動する
2. `analyzer-trigger` が IAM Access Analyzer の Findings を S3 に保存する
3. `policy-advisor` が Findings を読み取り、Bedrock で最小権限化案を作る
4. Terraform HCL を GitHub PR として作成する
5. Chatwork に通知する

### 1. 事前に決めておく値

最初に、今回使う値を手元で決めておくと後続がスムーズです。

| 項目 | 例 | 用途 |
|---|---|---|
| AWS リージョン | `ap-northeast-1` | すべての AWS リソース配置先 |
| GitHub オーナー | `your-org` | PR 作成先リポジトリの owner |
| GitHub リポジトリ名 | `iam-terraform-live` | PR 作成先リポジトリ名 |
| Chatwork ルーム ID | `123456789` | 通知先 |
| Bedrock モデル ID | `anthropic.claude-sonnet-4-5` | 最小権限案の生成に使用 |

### 2. AWS CLI の接続先を確認する

まず、今から作業する AWS アカウントとリージョンが意図どおりか確認します。

```bash
aws sts get-caller-identity
aws configure list
```

確認ポイント:

- `Account` が対象 AWS アカウントであること
- `region` が `ap-northeast-1` になっていること

必要なら明示的にリージョンを付けて実行してください。

```bash
export AWS_REGION=ap-northeast-1
```

### 3. GitHub Personal Access Token を用意する

GitHub で Personal Access Token を発行し、少なくとも次の書き込み権限を持たせます。

- `Contents`
- `Pull requests`

このトークンは `policy-advisor` Lambda が GitHub API を使って、

- ブランチ作成
- `terraform/iam_policies/*.tf` のコミット
- PR 作成

を行うために必要です。

### 4. Chatwork API トークンを用意する

Chatwork 通知に使う API トークンと、通知先ルーム ID を控えます。

### 5. Secrets Manager にトークンを登録する

GitHub トークンと Chatwork トークンは、Lambda 環境変数へ直接入れず Secrets Manager に保存します。

```bash
# GitHub Personal Access Token（repo 相当の書き込み権限が必要）
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

作成後、ARN を控えます。

```bash
aws secretsmanager describe-secret \
  --secret-id "iam-least-privilege-advisor/github-token" \
  --region ap-northeast-1

aws secretsmanager describe-secret \
  --secret-id "iam-least-privilege-advisor/chatwork-token" \
  --region ap-northeast-1
```

確認ポイント:

- GitHub 用シークレットの中身が `{"token":"..."}` 形式
- Chatwork 用シークレットの中身が `{"api_token":"..."}` 形式

### 6. GitHub Actions 用 OIDC プロバイダーを設定する

このプロジェクトは、GitHub Actions から AWS へアクセスするときにアクセスキーではなく OIDC を使います。

AWS コンソールで次を設定します。

AWS コンソール → IAM → ID プロバイダー → プロバイダーを追加

| 項目 | 値 |
|---|---|
| プロバイダーのタイプ | OpenID Connect |
| プロバイダー URL | `https://token.actions.githubusercontent.com` |
| 対象者 | `sts.amazonaws.com` |

次に、GitHub Actions が Assume Role する IAM ロールを作成し、以下の信頼ポリシーを設定します。

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

このロールには、少なくともこの Terraform を `plan` / `apply` できる権限を付けます。

### 7. GitHub Actions Secrets を設定する

GitHub リポジトリの Settings → Secrets and variables → Actions に以下を登録します。

| Secret 名 | 値 |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | OIDC ロールの ARN |
| `GITHUB_TOKEN_SECRET_ARN` | GitHub Token シークレットの ARN |
| `CHATWORK_SECRET_ARN` | Chatwork Token シークレットの ARN |
| `CHATWORK_ROOM_ID` | Chatwork 通知先ルーム ID |
| `GITHUB_OWNER` | GitHub オーナー名 |
| `GITHUB_REPO` | GitHub リポジトリ名 |

この設定により、GitHub Actions の `deploy.yml` が `terraform plan` と `terraform apply` を実行できるようになります。

### 8. `terraform.tfvars` を作成する

Terraform 用の変数ファイルを作成します。

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を開いて、最低限次の値を実環境のものに置き換えてください。

```hcl
project_name = "iam-least-privilege-advisor"
environment  = "dev"
aws_region   = "ap-northeast-1"

github_owner = "your-github-username-or-org"
github_repo  = "your-iam-terraform-repo"

chatwork_room_id = "123456789"

bedrock_model_id = "anthropic.claude-sonnet-4-5"

github_token_secret_arn = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:iam-least-privilege-advisor/github-token-xxxxxx"
chatwork_secret_arn     = "arn:aws:secretsmanager:ap-northeast-1:123456789012:secret:iam-least-privilege-advisor/chatwork-token-xxxxxx"
```

値の意味:

- `github_owner`, `github_repo`
  - PR の作成先
- `chatwork_room_id`
  - PR 作成成功時の通知先
- `github_token_secret_arn`, `chatwork_secret_arn`
  - Lambda が Secrets Manager から取得するトークン
- `bedrock_model_id`
  - IAM 最小権限案の生成モデル

### 9. Terraform で AWS リソースをデプロイする

ここからはユーザー自身で Terraform を実行します。

```bash
cd terraform
terraform init
terraform plan
terraform apply
```

`apply` が成功すると、主に次の AWS リソースが作成されます。

- S3 バケット
- 2 つの Lambda 関数
- 2 つの Lambda 実行ロール
- Access Analyzer
- EventBridge Scheduler

確認ポイント:

- `results_bucket_name`
- `analyzer_trigger_function_name`
- `policy_advisor_function_name`

これらは Terraform output や AWS コンソールで確認できます。

### 10. Lambda と Access Analyzer ができているか確認する

```bash
aws lambda get-function \
  --function-name iam-least-privilege-advisor-analyzer-trigger \
  --region ap-northeast-1

aws lambda get-function \
  --function-name iam-least-privilege-advisor-policy-advisor \
  --region ap-northeast-1

aws accessanalyzer list-analyzers \
  --region ap-northeast-1
```

確認ポイント:

- `iam-least-privilege-advisor-analyzer-trigger` が存在する
- `iam-least-privilege-advisor-policy-advisor` が存在する
- `iam-least-privilege-advisor-unused-access` が作成されている

### 11. 手動で 1 回動かしてみる

最初の確認は、週次スケジュールを待たずに `analyzer-trigger` を直接実行するのが分かりやすいです。

```bash
aws lambda invoke \
  --function-name iam-least-privilege-advisor-analyzer-trigger \
  --invocation-type RequestResponse \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json \
  --region ap-northeast-1

cat /tmp/response.json
```

期待するレスポンス例:

```json
{
  "statusCode": 200,
  "analyzer_arn": "arn:aws:access-analyzer:ap-northeast-1:123456789012:analyzer/...",
  "findings_count": 3,
  "s3_key": "analyzer-results/2026/05/06/findings.json"
}
```

### 12. S3 に Findings が保存されたことを確認する

```bash
aws s3 ls s3://<BUCKET_NAME>/analyzer-results/ --recursive --region ap-northeast-1
aws s3 cp s3://<BUCKET_NAME>/analyzer-results/<YYYY>/<MM>/<DD>/findings.json - | jq .
```

`<BUCKET_NAME>` が分からない場合は Terraform output か AWS コンソールで確認してください。

見たいポイント:

- `scan_date`
- `findings`
- `total_count`

### 13. CloudWatch Logs で Lambda の実行結果を確認する

```bash
# analyzer-trigger のログ
aws logs tail /aws/lambda/iam-least-privilege-advisor-analyzer-trigger \
  --follow --region ap-northeast-1

# policy-advisor のログ
aws logs tail /aws/lambda/iam-least-privilege-advisor-policy-advisor \
  --follow --region ap-northeast-1
```

正常系で見えるログのイメージ:

- `analyzer-trigger 開始`
- `取得した Findings 数: ...`
- `S3 保存完了`
- `policy-advisor 非同期起動完了`
- `policy-advisor 完了: processed=... pr_created=... skipped=...`

### 14. GitHub PR が作成されたことを確認する

PR 作成先リポジトリを開き、以下を確認します。

- `fix/iam-least-privilege-YYYYMMDD-...` 形式のブランチができている
- `terraform/iam_policies/*.tf` が追加されている
- PR タイトルが `[IAM] <role_name> の最小権限化 (YYYY/MM/DD)` 形式になっている

PR が作成されていれば、Bedrock 生成、AI 出力検証、Terraform 変換、GitHub API 呼び出しまで一連の流れが通っています。

### 15. Chatwork 通知を確認する

通知先ルームに、PR URL を含む通知が届いていることを確認します。

届かない場合は次を確認します。

- `CHATWORK_SECRET_ARN` が正しいか
- `CHATWORK_ROOM_ID` が正しいか
- `policy-advisor` の CloudWatch Logs にエラーが出ていないか

## 動作確認チェックリスト

ハンズオン完了の目安は次のとおりです。

- Terraform `apply` が成功した
- 2 つの Lambda が作成された
- Access Analyzer が作成された
- 手動実行で `findings.json` が S3 に保存された
- GitHub に Terraform PR が作成された
- Chatwork に通知が届いた

## よくあるつまずきポイント

### 1. GitHub PR が作成されない

確認する点:

- GitHub PAT に `Contents` と `Pull requests` の書き込み権限があるか
- `github_owner`, `github_repo` が正しいか
- Secrets Manager に保存した JSON キー名が `token` になっているか

### 2. Chatwork 通知が来ない

確認する点:

- Secrets Manager のキー名が `api_token` になっているか
- `CHATWORK_ROOM_ID` が正しいか
- Chatwork API トークンが有効か

### 3. Findings が 0 件で PR ができない

これは異常ではありません。未使用アクションが無ければ、PR は作成されません。

### 4. Bedrock 呼び出しで失敗する

確認する点:

- 対象リージョンで指定モデルが利用可能か
- Lambda 実行ロールがそのモデル ARN に対して `bedrock:InvokeModel` を持っているか

## AI 出力のレビューポイント

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
