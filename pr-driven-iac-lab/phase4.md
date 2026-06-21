# ✅Phase 4: Terraform Cloud PR-driven ワークフロー実装

## このフェーズの前提

- Phase 3（Atlantis）が完了していること
- Terraform Cloud アカウントが作成済み（無料: https://app.terraform.io/signup/account）
- GitHub リポジトリが存在していること

## このフェーズの目的

- Terraform Cloud の VCS-driven ワークフローを実装
- GitHub Actions から TFC API を叩く CI-driven ワークフローも実装
- AtlantisとTFCの体験を比較できる状態にする

## Terraform Cloud の2つのワークフロー

TFCには複数のワークフローがある。このラボでは両方を体験する：

### A. VCS-driven ワークフロー（推奨、メイン）

```
PR open → TFC が自動 plan → PR に Checks で結果表示
PR merge → TFC が自動 apply
```

設定: TFC Workspace に GitHub リポジトリを直接接続。
AtlantisのWebhookと似ているが、TFC側でUIと状態管理が一体化。

### B. CLI-driven / API-driven ワークフロー（補完的に体験）

```
PR open → GitHub Actions が TFC API をコール → plan 実行
PR コメント/Checks → merge → GitHub Actions が apply をトリガー
```

設定: GitHub Actions から `TFE_TOKEN` で TFC API を呼び出す。

## タスク 4-1: Terraform Cloud セットアップ

### 4-1-1: Organization と Workspace の作成

1. https://app.terraform.io にログイン
2. Organization を作成（例: `takuya-iac-lab`）
3. Workspace を作成:
   - Type: **Version Control Workflow**（VCS-driven）
   - Name: `sample-infra-dev`
   - VCS: GitHub → `pr-driven-iac-lab` リポジトリを選択
   - Terraform Working Directory: `terraform/sample-infra`
   - Auto Apply: **OFF**（PRへのplan自動実行のみ、applyは手動）

### 4-1-2: Workspace 変数の設定

TFC Workspace の Variables タブで設定：

**Environment Variables（Sensitive）:**
```
AWS_ACCESS_KEY_ID     = （TFC専用IAMユーザーのアクセスキー）
AWS_SECRET_ACCESS_KEY = （TFC専用IAMユーザーのシークレットキー）
AWS_DEFAULT_REGION    = ap-northeast-1
```

**注意**: TFCはOIDCもサポートしているが、設定が複雑なため今回はアクセスキー方式。
本番環境では OIDC が推奨（TFC Dynamic Provider Credentials）。
このコメントをWorkspaceの説明欄に記載すること。

**TFC専用IAMユーザーの作成:**

```bash
# TFC専用IAMユーザー（最小権限）
aws iam create-user --user-name tfc-sample-infra-deployer

# sample-infraが管理するリソースへの権限のみ付与
# （Atlantisのタスクロールと同等の権限）
aws iam attach-user-policy \
  --user-name tfc-sample-infra-deployer \
  --policy-arn arn:aws:iam::ACCOUNT_ID:policy/sample-infra-deployer-policy

# アクセスキー作成
aws iam create-access-key --user-name tfc-sample-infra-deployer
```

### 4-1-3: backend の切り替え

**重要**: TFCを使う場合、S3バックエンドからTFCバックエンドに切り替える。

`terraform/sample-infra/backend.tf` を以下に変更：

```hcl
# TFC使用時はTerraform Cloudがステート管理を担う
# S3バックエンドは不要になる
terraform {
  cloud {
    organization = "takuya-iac-lab"  # 自分のOrg名に変更

    workspaces {
      name = "sample-infra-dev"
    }
  }
}
```

```bash
# バックエンド切り替えの実行
cd terraform/sample-infra
terraform login  # TFCにログイン（ブラウザが開く）
terraform init -migrate-state  # S3からTFCにステートを移行
```

ステート移行後、TFC UIの Workspace > States で移行されたステートを確認すること。

## タスク 4-2: VCS-driven ワークフローの体験

### シナリオ: sample-infra に新しいタグを追加

```bash
git checkout main
git pull origin main
git checkout -b feature/tfc-test-add-tag

# terraform/sample-infra/main.tf のS3バケットtagsに追加:
# TerraformBackend = "terraform-cloud"

git add terraform/sample-infra/main.tf
git commit -m "feat(tfc): TFCバックエンド識別タグを追加"
git push origin feature/tfc-test-add-tag
gh pr create \
  --title "feat: TFC動作確認 - タグ追加" \
  --body "## 変更内容
TFCバックエンド移行後の初回PR-drivenテスト

## 確認事項
- [ ] TFC が自動でplan を実行する
- [ ] GitHub Checks にplan結果が表示される
- [ ] TFC UI で Runs タブを確認できる"
```

### 確認ポイント

1. PR作成後、GitHub Checks タブに `Terraform Cloud / sample-infra-dev` が出現
2. TFC UI（https://app.terraform.io）の Workspace > Runs でplan実行を確認
3. planが完了したら TFC UI から **Confirm & Apply** をクリック
   （または Auto Apply を ONにしてmerge後自動applyも体験可能）

## タスク 4-3: GitHub Actions + TFC API ワークフロー

`.github/workflows/tfc-pr-workflow.yml` を作成：

```yaml
name: Terraform Cloud PR Workflow

on:
  pull_request:
    paths:
      - 'terraform/sample-infra/**'
    types: [opened, synchronize, reopened]
  push:
    branches: [main]
    paths:
      - 'terraform/sample-infra/**'

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  terraform-plan:
    name: Terraform Plan (TFC)
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          cli_config_credentials_token: ${{ secrets.TF_API_TOKEN }}

      - name: Terraform Init
        working-directory: terraform/sample-infra
        run: terraform init

      - name: Terraform Format Check
        working-directory: terraform/sample-infra
        run: terraform fmt -check

      - name: Terraform Plan
        id: plan
        working-directory: terraform/sample-infra
        run: terraform plan -no-color -input=false
        continue-on-error: true

      # PRにplanコメントを投稿（Atlantisと同等の体験を再現）
      - name: PR Comment with Plan Result
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const output = `### Terraform Plan Result 🔍
            
            **Plan Status**: ${{ steps.plan.outcome == 'success' && '✅ Success' || '❌ Failed' }}
            
            <details><summary>Show Plan Output</summary>
            
            \`\`\`hcl
            ${{ steps.plan.outputs.stdout }}
            \`\`\`
            
            </details>
            
            *Workflow: \`${{ github.workflow }}\` | Run: \`${{ github.run_id }}\`*`;
            
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Plan Status Check
        if: steps.plan.outcome == 'failure'
        run: exit 1

  terraform-apply:
    name: Terraform Apply (TFC)
    runs-on: ubuntu-latest
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    environment: production  # GitHub Environment での承認ゲート
    
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          cli_config_credentials_token: ${{ secrets.TF_API_TOKEN }}

      - name: Terraform Init
        working-directory: terraform/sample-infra
        run: terraform init

      - name: Terraform Apply
        working-directory: terraform/sample-infra
        run: terraform apply -auto-approve -input=false
```

### GitHub Secrets の設定

```bash
gh secret set TF_API_TOKEN --body "$(cat ~/.terraform.d/credentials.tfrc.json | jq -r '.credentials["app.terraform.io"].token')"
```

### GitHub Environment の設定

1. リポジトリ Settings > Environments > New environment
2. 名前: `production`
3. Required reviewers: 自分のGitHubアカウントを追加
4. これにより、merge後の apply に承認ゲートが設置される

## タスク 4-4: TFC UI の探索

以下のTFC UI機能を確認・記録すること（ADR記述の参考にする）：

1. **Runs タブ**: plan/applyの実行履歴、実行時間、ステータス
2. **States タブ**: ステートファイルの履歴（バージョン管理）
3. **Variables タブ**: 環境変数の設定画面
4. **Settings > Notifications**: Slackやメール通知の設定
5. **Settings > Team Access**: ワークスペースへのアクセス権限管理

各機能について「Atlantisで同等のことをやろうとしたらどうなるか」をメモすること。

## タスク 4-5: ワークフロー体験 シナリオ「apply の確認」

```bash
git checkout -b feature/tfc-apply-test

# IAMロール名を変更する（destroyが発生する変更）
# sample-infra/main.tf の aws_iam_role の name を変更：
# "sample-infra-s3-reader-dev-v2" に変更

git add terraform/sample-infra/main.tf
git commit -m "feat: IAMロール名をv2に更新（TFCでdestroyを含む変更のテスト）"
git push origin feature/tfc-apply-test
gh pr create --title "feat: IAMロール名変更テスト" --body "TFCでdestroyを含む変更の挙動を確認"
```

### 確認ポイント

1. plan に `1 to add, 1 to destroy` が含まれることを確認
2. TFC UI で destroy の詳細を確認（どのリソースが削除されるか）
3. GitHub Checks のplanコメントに destroy が表示されることを確認
4. apply は **実行せず** PRをクローズする（destructiveな変更のため）

```bash
gh pr close {PR番号}
git checkout main
```

## Phase 4 完了確認チェックリスト

- [ ] TFC Organization と Workspace が作成済み
- [ ] VCS-driven ワークフローで PR → plan が自動実行された
- [ ] TFC UI の Runs タブで実行履歴を確認した
- [ ] S3バックエンドからTFCへのステート移行が完了した
- [ ] `.github/workflows/tfc-pr-workflow.yml` が動作している
- [ ] GitHub Secrets に `TF_API_TOKEN` が設定済み
- [ ] GitHub Environment `production` に承認ゲートが設定済み
- [ ] Atlantisと比較した際の相違点を5つ以上メモしている

## 口頭説明チェックポイント（Phase 4終了後）

以下を15分間、ノートなしで説明できること：

1. **TFCのVCS-drivenとCI-driven（API-driven）の違い**
   - それぞれのトリガー、実行環境、権限管理の違い
   - どちらが「Atlantisに近い体験」か

2. **TFCのState管理がS3+DynamoDBより優れている点と劣る点**
   - 暗号化、バージョン管理、ロック機構の比較
   - コスト（TFC Free: 500リソース上限）

3. **GitHub Environment の承認ゲートの意味**
   - `apply_requirements: approved` (Atlantis) との設計思想の違い
   - どちらがセキュリティ上より堅牢か