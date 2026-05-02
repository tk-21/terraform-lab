# ✅Phase 4: 統合パイプライン

## このフェーズで達成すること

Terraform output → Ansible Dynamic Inventory → SSMセッションマネージャー接続の
完全パイプラインをGitHub Actions OIDCで自動化する。

## Phase 3からの引き継ぎ

- Moleculeテスト通過済みのnginxロールが存在する
- EC2インスタンスが起動済み（`Role=web`タグ付き）
- SSMパラメータが設定済み

---

## Task 4-1: GitHub Actions OIDCロールのTerraform定義

`terraform/environments/dev/github_actions_oidc.tf` を作成してください:

```hcl
# =============================================================================
# GitHub Actions OIDC認証設定
# 設計思想: 静的アクセスキーを一切使わない
# OIDCにより「このリポジトリのこのブランチからのみ」AWS操作を許可する
# =============================================================================

data "aws_caller_identity" "current" {}

# GitHub ActionsのOIDCプロバイダー（AWSアカウントに1つだけ作成）
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHubのOIDCサービスの証明書フィンガープリント
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

# GitHub Actions実行ロール
resource "aws_iam_role" "github_actions" {
  name = "handson-dev-github-actions-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          # セキュリティ設計: 特定リポジトリのmainブランチからのみ許可
          "token.actions.githubusercontent.com:sub" = "repo:YOUR_GITHUB_ORG/tf-ansible-nginx-pipeline:ref:refs/heads/main"
        }
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

# Terraform操作用ポリシー（最小権限）
resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "handson-dev-github-actions-terraform-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "TerraformStateAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::handson-dev-tfstate",
          "arn:aws:s3:::handson-dev-tfstate/*"
        ]
      },
      {
        Sid    = "TerraformLockAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:*:table/handson-dev-tflock"
      },
      {
        Sid    = "EC2ReadOnly"
        Effect = "Allow"
        Action = ["ec2:Describe*"]
        Resource = "*"
      },
      {
        Sid    = "SSMReadForAnsible"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter", "ssm:GetParameters",
          "ssm:GetParametersByPath", "ssm:DescribeInstanceInformation",
          "ssm:StartSession", "ssm:TerminateSession",
          "ssm:SendCommand", "ssm:ListCommandInvocations"
        ]
        Resource = "*"
      }
    ]
  })
}

output "github_actions_role_arn" {
  description = "GitHub ActionsワークフローのAWS_ROLE_ARNに設定する"
  value       = aws_iam_role.github_actions.arn
}
```

---

## Task 4-2: Terraformワークフローの生成

`.github/workflows/terraform.yml` を作成してください:

```yaml
# =============================================================================
# Terraform CI/CDワークフロー
# 設計思想:
#   PR时: plan結果をPRコメントに自動投稿（レビュー支援）
#   mainマージ時: applyを自動実行
#   静的アクセスキー不使用: OIDC認証のみ
# =============================================================================

name: Terraform

on:
  push:
    branches: [main]
    paths:
      - 'terraform/**'
  pull_request:
    branches: [main]
    paths:
      - 'terraform/**'

permissions:
  id-token: write   # OIDC認証に必須
  contents: read
  pull-requests: write  # PRコメント書き込み用

env:
  TF_VERSION: "1.7.0"
  AWS_REGION: ap-northeast-1
  WORKING_DIR: terraform/environments/dev

jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ${{ env.WORKING_DIR }}

    steps:
      - uses: actions/checkout@v4

      - name: AWS OIDC認証
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
          # 静的キー（aws-access-key-id等）を一切指定しない

      - name: Terraform セットアップ
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: terraform init
        run: terraform init

      - name: terraform validate
        run: terraform validate

      - name: terraform fmt チェック
        run: terraform fmt -check -recursive
        # fmtが通らないコードはCIで落とす

      - name: terraform plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        continue-on-error: true

      - name: PRにplanコメントを投稿
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const output = `## Terraform Plan 結果

            **Plan Status**: ${{ steps.plan.outcome == 'success' && '✅ 成功' || '❌ 失敗' }}

            <details><summary>Plan詳細を表示</summary>

            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\`

            </details>

            *実行者: @${{ github.actor }}, ワークフロー: ${{ github.workflow }}*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

      - name: planが失敗した場合はCIを落とす
        if: steps.plan.outcome == 'failure'
        run: exit 1

      - name: terraform apply（mainブランチのみ）
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve tfplan
```

---

## Task 4-3: Ansibleワークフローの生成

`.github/workflows/ansible.yml` を作成してください:

```yaml
# =============================================================================
# Ansible CI/CDワークフロー
# 設計思想:
#   1. terraform applyの後に自動実行（インフラ変更後の構成適用）
#   2. SSMセッションマネージャー経由でSSHキー不要
#   3. --checkで本番適用前にドライランを実施
# =============================================================================

name: Ansible

on:
  # Terraform applyの後に自動実行
  workflow_run:
    workflows: ["Terraform"]
    types: [completed]
    branches: [main]
  # 手動実行も可能
  workflow_dispatch:
    inputs:
      check_mode:
        description: 'ドライラン（--check）で実行するか'
        required: true
        default: 'true'
        type: boolean

permissions:
  id-token: write
  contents: read

jobs:
  ansible:
    # Terraformが成功した場合のみ実行
    if: >
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: AWS OIDC認証
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ap-northeast-1

      - name: Python・Ansibleセットアップ
        run: |
          pip install ansible boto3 botocore amazon.aws

      - name: Ansibleコレクションのインストール
        run: |
          ansible-galaxy collection install amazon.aws community.aws

      - name: ansible-lint（コード品質チェック）
        working-directory: ansible
        run: ansible-lint site.yml

      - name: Dynamic Inventoryの動作確認
        working-directory: ansible
        run: |
          ansible-inventory --list | jq '.web.hosts'
          # webグループにホストが存在することを確認

      - name: Ansible ドライラン（--check）
        working-directory: ansible
        run: |
          ansible-playbook site.yml --check --diff
        # --diff: 設定ファイルの変更差分を表示

      - name: Ansible 本番適用（mainブランチかつdryrun=falseの場合）
        working-directory: ansible
        if: >
          github.ref == 'refs/heads/main' &&
          (github.event.inputs.check_mode != 'true')
        run: |
          ansible-playbook site.yml
```

---

## Task 4-4: Terraform → Ansible 引き渡し設計ドキュメント

`docs/terraform-ansible-handoff.md` を作成してください:

```markdown
# Terraform → Ansible 設定値受け渡し設計

## 問題: なぜSSMパラメータを経由するのか

### アンチパターン: Terraform outputをAnsible varsに直接書く
```bash
# ❌ アンチパターン
terraform output instance_id >> ansible/vars/ec2.yml
```
問題点:
- 生成されたファイルをgit管理するとstateとvarsが二重管理になる
- CI/CD環境でのファイル生成・参照のタイミング問題が発生する

### 採用パターン: SSMパラメータを中間バスとして使用

```
Terraform → SSMパラメータ書き込み → Ansible実行時に読み取り
```

メリット:
- 設定値の信頼できる唯一の情報源（Single Source of Truth）がSSM
- AnsibleはSSMから常に最新の値を取得する
- 値の変更はTerraform applyだけで完結する
- GitにはSSMのパラメータ名だけを書けばよい（値のハードコード不要）

## Dynamic Inventoryの仕組み

```
AWS EC2 API
    ↓（タグフィルタ: AnsibleManaged=true, state=running）
aws_ec2 plugin
    ↓（instance-idをホスト名として使用）
Ansibleホスト: i-0123456789abcdef
    ↓（ansible_connection=aws_ssm）
SSMセッションマネージャー接続
    ↓（SSHキー不要、ポート22不要）
EC2インスタンス
```
```

---

## Phase 4 実行コマンド

```bash
# OIDCロールARNをGitHub Secretsに設定
# Settings > Secrets > Actions > New repository secret
# Name: AWS_ROLE_ARN
# Value: terraform output github_actions_role_arn

# ローカルでのAnsible実行確認
cd ansible
ansible-inventory --list  # Dynamic Inventoryの動作確認
ansible-playbook site.yml --check  # ドライラン
ansible-playbook site.yml  # 本番適用

# GitHub Actionsのトリガー
git add .
git commit -m "feat: add nginx configuration"
git push origin main
```

## Phase 5への引き継ぎ情報

- Terraformモジュール（vpc, compute, ssm）が全て動作確認済み
- Ansible Roleがmainブランチへのpushで自動適用される
- GitHub Actions OIDCが設定済みで静的キー不使用