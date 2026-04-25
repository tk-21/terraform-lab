# ✅Phase4: GitHub Actions OIDC + Plan/Apply分離 CI/CD

## Phaseサマリー（前Phaseまでの状態）
Phase1-3完了済み:
- Terraform: VPC / SG / EC2 / ALB 稼働中
- Ansible: Nginx + Flask デプロイ済み、ALBヘルスチェックHealthy
- S3 remote backend稼働中
- GitHubリポジトリにコードをpush済み（前提）

## このPhaseの目的
IAMアクセスキーを一切使わずOIDCでGitHub ActionsからAWSを操作。
PRで`plan`、mainマージで`apply`の安全なワークフローを構築する。

---

## Task 1: OIDC用IAMリソースをTerraformで追加

`terraform/modules/github_actions_oidc/` を新規作成:

### main.tf

```hcl
# GitHub Actions OIDC プロバイダー
# AWSアカウントに1つだけ作成（既存の場合はdata sourceで参照）
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"

  # GitHubのOIDCサムプリント（2024年更新版）
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd"
  ]

  client_id_list = ["sts.amazonaws.com"]
}

# GitHub Actions用 IAM Role
resource "aws_iam_role" "github_actions" {
  name = "${var.project}-${var.environment}-github-actions-role"

  # OIDCフェデレーション信頼ポリシー
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.github.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # セキュリティ: 対象リポジトリのみに絞る
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.github_repo}:*"
        }
      }
    }]
  })
}

# Terraform操作に必要な最小権限ポリシー
resource "aws_iam_role_policy" "github_actions_terraform" {
  name = "terraform-operations"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # S3 state操作
        Effect = "Allow"
        Action = [
          "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
          "s3:ListBucket", "s3:GetBucketVersioning"
        ]
        Resource = [
          "arn:aws:s3:::tap-terraform-state-*",
          "arn:aws:s3:::tap-terraform-state-*/*"
        ]
      },
      {
        # DynamoDB state lock
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem", "dynamodb:PutItem",
          "dynamodb:DeleteItem", "dynamodb:DescribeTable"
        ]
        Resource = "arn:aws:dynamodb:ap-northeast-1:*:table/tap-terraform-lock"
      },
      {
        # EC2/VPC/ALB操作（Read + Write）
        Effect = "Allow"
        Action = [
          "ec2:*", "elasticloadbalancing:*",
          "iam:GetRole", "iam:GetInstanceProfile",
          "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
          "iam:CreateRole", "iam:DeleteRole",
          "iam:AttachRolePolicy", "iam:DetachRolePolicy",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
          "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
          "iam:PassRole", "iam:TagRole",
          "ssm:*",
          "cloudwatch:*",
          "logs:*"
        ]
        Resource = "*"
      }
    ]
  })
}
```

### variables.tf
```hcl
variable "project"     { type = string }
variable "environment" { type = string }
variable "github_org"  { type = string, description = "GitHubオーガニゼーション名またはユーザー名" }
variable "github_repo" { type = string, description = "リポジトリ名" }
```

### outputs.tf
```hcl
output "github_actions_role_arn" {
  value       = aws_iam_role.github_actions.arn
  description = "GitHub ActionsワークフローのIAM Role ARN（GitHub Secretsに設定する）"
}
```

`environments/dev/main.tf` にこのモジュールを追加し、`terraform apply`

---

## Task 2: GitHub Secretsの設定

以下をGitHubリポジトリの `Settings > Secrets and variables > Actions` に追加:

| Secret名 | 値 |
|---------|---|
| `AWS_ROLE_ARN` | Task1のoutput `github_actions_role_arn` |
| `AWS_REGION` | `ap-northeast-1` |

**注意**: アクセスキーは絶対に設定しない

---

## Task 3: terraform-plan.yml ワークフロー

`.github/workflows/terraform-plan.yml`:

```yaml
name: Terraform Plan

on:
  pull_request:
    branches: [main]
    paths:
      - 'terraform/**'

permissions:
  contents: read
  pull-requests: write      # PRにコメントするため
  id-token: write           # OIDC認証に必須

jobs:
  plan:
    name: Terraform Plan
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/environments/dev

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}
          # アクセスキー不要 - OIDCトークンで認証

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.6"

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive
        continue-on-error: true

      - name: Terraform Init
        id: init
        run: terraform init

      - name: Terraform Validate
        id: validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        continue-on-error: true

      # PRにplanの差分をコメントで投稿
      - name: Comment Plan Result on PR
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        env:
          PLAN: ${{ steps.plan.outputs.stdout }}
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const output = `#### Terraform Format 🖌 \`${{ steps.fmt.outcome }}\`
            #### Terraform Init ⚙️ \`${{ steps.init.outcome }}\`
            #### Terraform Validate 🤖 \`${{ steps.validate.outcome }}\`
            #### Terraform Plan 📖 \`${{ steps.plan.outcome }}\`

            <details><summary>Show Plan</summary>

            \`\`\`terraform
            ${process.env.PLAN}
            \`\`\`

            </details>

            *Pushed by: @${{ github.actor }}, Action: \`${{ github.event_name }}\`*`;

            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

      - name: Terraform Plan Status
        if: steps.plan.outcome == 'failure'
        run: exit 1
```

---

## Task 4: terraform-apply.yml ワークフロー

`.github/workflows/terraform-apply.yml`:

```yaml
name: Terraform Apply

on:
  push:
    branches: [main]
    paths:
      - 'terraform/**'

permissions:
  contents: read
  id-token: write    # OIDC認証に必須

jobs:
  apply:
    name: Terraform Apply
    runs-on: ubuntu-latest
    environment: production    # GitHub Environment保護ルールで承認フロー追加可能
    defaults:
      run:
        working-directory: terraform/environments/dev

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Configure AWS Credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.6"

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan（apply前の最終確認）
        run: terraform plan -no-color -out=tfplan

      - name: Terraform Apply
        run: terraform apply -auto-approve tfplan

      - name: Output ALB DNS
        run: |
          echo "### Deploy Complete 🚀" >> $GITHUB_STEP_SUMMARY
          echo "ALB DNS: $(terraform output -raw alb_dns_name)" >> $GITHUB_STEP_SUMMARY
```

---

## Task 5: .gitignore の更新

プロジェクトルートの `.gitignore` に追加:
```
# Terraform
**/.terraform/
*.tfplan
*.tfstate
*.tfstate.backup
.terraform.lock.hcl   # ロックファイルはコミットする場合もある（チームで統一）

# Ansible
ansible/vault_password
*.retry

# 秘密情報
*.pem
*.key
```

---

## 完了基準

- [ ] PRを作成するとTerraform Planがコメントで表示される
- [ ] mainマージでTerraform Applyが自動実行される
- [ ] GitHub ActionsのログにAWSアクセスキーが一切表示されない
- [ ] IAMコンソールで最後の認証が `AssumeRoleWithWebIdentity` であることを確認
- [ ] `aws iam get-role --role-name tap-dev-github-actions-role` でOIDC信頼ポリシーを確認

---

## セキュリティ補足

- OIDC条件の `StringLike` で特定リポジトリのみに制限している
- `environment: production` をapplyジョブに設定することで、GitHub Environmentの保護ルール（レビュアー承認必須など）を後から追加できる
- IAMポリシーは最小権限に留めており、`iam:CreateUser` 等の危険な権限は含まない