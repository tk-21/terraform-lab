# ✅Phase 1: 基盤構築 + サンプルインフラTerraformコード作成

## このフェーズの目的

- Terraform リモートステート用 S3 + DynamoDB を構築（bootstrap）
- AtlantisとTFCの両方が plan/apply する「サンプルインフラ」のTerraformコードを作成
- GitHub リポジトリ構造を整備

## 前提条件の確認

以下が完了していることを確認してから作業を開始すること：

1. AWS CLIが設定済み（`aws sts get-caller-identity` で確認）
2. Terraformがインストール済み（`terraform version` で確認）
3. GitHubリポジトリ `pr-driven-iac-lab` が作成済み（Public or Private）
4. GitHub CLIがインストール済み（`gh auth status` で確認）

## タスク 1-1: ディレクトリ構造の作成

以下のディレクトリ構造をすべて作成すること：

```
terraform/
  bootstrap/
  sample-infra/
  atlantis-infra/
.github/
  workflows/
docs/
  adr/
interview/
```

## タスク 1-2: bootstrap/main.tf の作成

`terraform/bootstrap/main.tf` を作成すること。

### 要件

- **S3バケット（Terraformステート保存用）**
  - バケット名: `tfstate-pr-driven-iac-lab-{AWSアカウントID}`（変数化すること）
  - バージョニング: 有効
  - サーバーサイド暗号化: AES256
  - パブリックアクセスブロック: 全項目 true
  - force_destroy: true（ラボ用）

- **DynamoDB テーブル（ステートロック用）**
  - テーブル名: `tfstate-lock-pr-driven-iac-lab`
  - billing_mode: `PAY_PER_REQUEST`（コスト最適化）
  - hash_key: `LockID`（String型）

- **プロバイダー設定**
  - リージョン: ap-northeast-1
  - required_version: `>= 1.6`
  - aws provider: `~> 5.0`

- **outputs.tf**
  - s3_bucket_name
  - dynamodb_table_name

### 日本語コメント要件

各リソースブロックの上に、なぜそのリソースが必要かを日本語で1行コメント記述。

## タスク 1-3: sample-infra の Terraform コード作成

AtlantisとTFCが実際にplan/applyする対象インフラ。
シンプルだが「変更のたびにPRを作ってレビューする」ことを体験できる構成にする。

### `terraform/sample-infra/main.tf`

以下のリソースを含めること：

**S3バケット（メインリソース）**
- バケット名: `sample-infra-{var.environment}-{AWSアカウントID}`
- タグ: `Environment`, `ManagedBy = "terraform"`, `Project = "pr-driven-iac-lab"`
- バージョニング: 有効
- パブリックアクセスブロック: 全項目 true

**IAM ポリシー（S3読み取り専用）**
- バケットへの `s3:GetObject`, `s3:ListBucket` のみ許可
- wildcard 禁止（バケットARNを明示）

**IAM ロール（EC2 assume用、デモ用途）**
- ロール名: `sample-infra-s3-reader-{var.environment}`（64文字以内）
- 上記ポリシーをアタッチ

### `terraform/sample-infra/variables.tf`

- `environment`: string, default = "dev", description付き
- `aws_account_id`: string, description付き（data source で取得する場合は不要）

### `terraform/sample-infra/backend.tf`

```hcl
terraform {
  backend "s3" {
    bucket         = "tfstate-pr-driven-iac-lab-PLACEHOLDER"
    key            = "sample-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    dynamodb_table = "tfstate-lock-pr-driven-iac-lab"
    encrypt        = true
  }
}
```

※ PLACEHOLDERはPhase1実行後に手動で置き換える（AWSアカウントIDが必要なため）

### `terraform/sample-infra/outputs.tf`

- s3_bucket_name
- s3_bucket_arn
- iam_role_arn

## タスク 1-4: .gitignore の作成

プロジェクトルートに `.gitignore` を作成。

```
# Terraform
**/.terraform/
*.tfstate
*.tfstate.backup
*.tfvars
!*.tfvars.example
.terraform.lock.hcl

# Secrets
*.pem
*.key
.env

# OS
.DS_Store
```

## タスク 1-5: atlantis.yaml の作成

プロジェクトルートに `atlantis.yaml` を作成。

```yaml
version: 3
automerge: false
delete_source_branch_on_merge: false

projects:
  - name: sample-infra
    dir: terraform/sample-infra
    workspace: default
    terraform_version: v1.6.0
    autoplan:
      when_modified:
        - "*.tf"
        - "../modules/**/*.tf"
      enabled: true
    apply_requirements:
      - approved
      - mergeable
```

## タスク 1-6: docs/architecture.md の作成

Mermaidアーキテクチャ図を含む `docs/architecture.md` を作成。

### 図の要件

以下2つのフローをMermaidで表現：

**図1: Atlantisフロー**
```
開発者 --PR open--> GitHub
GitHub --webhook--> Atlantis(ECS Fargate)
Atlantis --terraform plan--> AWS
Atlantis --planコメント--> GitHub PR
開発者 --atlantis apply コメント--> GitHub PR
GitHub --webhook--> Atlantis
Atlantis --terraform apply--> AWS
```

**図2: Terraform Cloudフロー**
```
開発者 --PR open--> GitHub
GitHub Actions --trigger--> Terraform Cloud
Terraform Cloud --terraform plan--> AWS
Terraform Cloud --planコメント(via GH Actions)--> GitHub PR
開発者 --PR approve + merge--> GitHub
GitHub Actions --apply trigger--> Terraform Cloud
Terraform Cloud --terraform apply--> AWS
```

## タスク 1-7: ADRテンプレートの作成

### `docs/adr/ADR-001-atlantis-vs-tfc.md`

```markdown
# ADR-001: AtlantisとTerraform Cloud の選択

## Status
Proposed

## Context
PR-driven IaC ワークフローを導入するにあたり、Atlantis（Self-hosted）と
Terraform Cloud（SaaS）のどちらを採用するかを検討した。

## Options Considered

### Option A: Atlantis on ECS Fargate
- Self-hosted のため、ネットワーク・IAM・インフラ管理が必要
- カスタマイズ性が高い
- コスト: ECS Fargate + ALB の実行コスト

### Option B: Terraform Cloud (Free Tier)
- SaaS のためインフラ管理不要
- 500リソースまで無料
- State管理・UI・監査ログが付属

## Decision

<!-- ここはTakuya本人が記述すること。AIによる記入禁止。 -->
<!-- Phase 5完了後、両方を体験した上で記述する -->

## Consequences

<!-- Phase 5完了後に記述 -->
```

### `docs/adr/ADR-002-atlantis-on-ecs.md`

```markdown
# ADR-002: Atlantis のホスティング先として ECS Fargate を選択

## Status
Proposed

## Context
Atlantis をself-hostする場合のコンピュート選択肢（EC2, ECS, EKS, Lambda）を検討。

## Options Considered

### Option A: EC2
### Option B: ECS Fargate（採用）
### Option C: EKS

## Decision

<!-- ここはTakuya本人が記述すること。AIによる記入禁止。 -->

## Consequences

<!-- Phase 2完了後に記述 -->
```

## タスク 1-8: bootstrap の apply 実行

以下の手順を実行し、出力を確認すること：

```bash
cd terraform/bootstrap
terraform init
terraform plan
terraform apply -auto-approve
```

apply成功後、出力されたS3バケット名を `terraform/sample-infra/backend.tf` の PLACEHOLDER に記入すること。

## Phase 1 完了確認チェックリスト

- [ ] `terraform/bootstrap/` apply 成功、S3バケットとDynamoDBが作成済み
- [ ] `terraform/sample-infra/` の全.tfファイルが作成済み
- [ ] `terraform/sample-infra/backend.tf` のPLACEHOLDERが実際のバケット名に置換済み
- [ ] `atlantis.yaml` がプロジェクトルートに存在
- [ ] `docs/architecture.md` にMermaid図が2つ存在
- [ ] `docs/adr/ADR-001-atlantis-vs-tfc.md` のDecisionセクションが空欄（AI記入禁止）
- [ ] `.gitignore` が存在し、*.tfstateが含まれる

## 口頭説明チェックポイント（Phase 1終了後）

以下を15分間、ノートなしで説明できること：

1. **なぜ Terraform のリモートステートが必要か**
   - ローカルステートの問題点（チーム複数人、CI/CD環境）
   - S3 + DynamoDB の役割分担（保存 vs ロック）

2. **bootstrapを別ディレクトリに分離した理由**
   - ステートバックエンド自体をTerraformで管理する鶏卵問題
   - bootstrap は手動apply、以降は PR-driven

3. **AtlantisとTFCの違いの仮説**（まだ体験前でよい）
   - 現時点でどちらが自社/チームに向いていると思うか