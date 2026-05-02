# ✅Phase 1: 設計思想の言語化

## このフェーズで達成すること

「TerraformとAnsibleをなぜ分けるのか」「何をどちらで管理するのか」を、
コードを書く前に言語化・構造化する。

前フェーズの出力: なし（Phase 1がスタート地点）

---

## Task 1-1: ADRファイルの生成

以下の内容で `docs/adr/ADR-001-terraform-ansible-boundary.md` を作成してください。

### ADR-001: TerraformとAnsibleの責務分界

**ステータス**: 採用

**コンテキスト**:
インフラ構築においてTerraform（IaC）とAnsible（Configuration Management）の両方を使用する。
それぞれ何を管理すべきかの判断基準を明示する。

**決定**:

| 管理対象 | Terraform | Ansible | 理由 |
|---------|-----------|---------|------|
| VPC/サブネット/IGW | ✅ | ❌ | 作成後は変更頻度が低いImmutableリソース |
| EC2インスタンス | ✅ | ❌ | AMI・インスタンスタイプはIaCで宣言的に管理 |
| セキュリティグループ | ✅ | ❌ | ネットワーク設計はTerraform stateで追跡必須 |
| OS設定・ミドルウェア | ❌ | ✅ | インスタンス起動後の設定変更が発生するMutableな領域 |
| nginx設定ファイル | ❌ | ✅ | アプリ要件変更に追随するため頻繁に変更される |
| SSMパラメータ（設定値） | ✅ | 読取のみ | Ansibleへの設定受け渡し口としてTerraformが作成 |
| cronジョブ | ❌ | ✅ | OSレイヤーの設定はAnsibleで管理 |

**結論の根拠**:
- Terraform: **「存在するかどうか」** を管理する（Immutable Infrastructure）
- Ansible: **「どういう状態にあるか」** を管理する（Configuration Management）
- 境界の判断軸: `terraform destroy` したら消えてほしいものか？→ Terraform / 消えなくていいものか？→ Ansible

**否定した選択肢**:
- user_dataだけで全部やる → 変更のたびにEC2再作成が必要になり運用不可
- Ansibleだけで全部やる → stateがないため差分管理・依存関係解決が困難

---

## Task 1-2: terraform stateの正体を解説するドキュメント生成

`docs/terraform-state-deep-dive.md` を以下の構成で作成してください。

### セクション構成

1. **stateとは何か**
   - JSONファイルとしてのstateの実体（実際のJSON例を含める）
   - stateが「知っている」3つのこと: リソースID、属性値、依存関係グラフ

2. **stateがないと何が起きるか**
   - `terraform apply` を2回実行したとき何が起きるか
   - ドリフト（手動変更）を検知できない問題

3. **remote stateのアーキテクチャ**
   ```hcl
   # なぜS3 + DynamoDBなのかをコメントで説明した設定例
   terraform {
     backend "s3" {
       bucket         = "handson-dev-tfstate"
       key            = "handson/dev/terraform.tfstate"
       region         = "ap-northeast-1"
       encrypt        = true          # 静止時暗号化：stateにはDB接続情報等が含まれる
       dynamodb_table = "handson-dev-tflock"  # 複数人の同時apply防止
     }
   }
   ```

4. **stateを直接触ってはいけないアンチパターン**
   - `terraform state rm` の正しい使いどころと危険性
   - `terraform import` が必要になる状況とその手順

---

## Task 1-3: bootstrap用Terraformコードの生成

tfstate管理用のS3バケットとDynamoDBテーブルを作成するブートストラップコードを
`terraform/bootstrap/` 配下に生成してください。

### 生成するファイル

**`terraform/bootstrap/main.tf`**:
```hcl
# ブートストラップ: このコードだけはローカルstateで管理する
# 理由: tfstate管理用リソース自体をremote stateで管理すると鶏と卵になるため

terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # ここだけlocal backend（意図的）
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# tfstate保存用S3バケット
resource "aws_s3_bucket" "tfstate" {
  bucket = "${var.project}-${var.environment}-tfstate"

  # 誤削除防止: terraform destroyしてもバケットを消さない
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"  # stateのバージョン管理でロールバック可能にする
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"  # stateにはシークレット情報が含まれるため暗号化必須
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DynamoDBロックテーブル
resource "aws_dynamodb_table" "tflock" {
  name         = "${var.project}-${var.environment}-tflock"
  billing_mode = "PAY_PER_REQUEST"  # ハンズオン用: 固定費ゼロ
  hash_key     = "LockID"           # Terraformが要求する固定キー名

  attribute {
    name = "LockID"
    type = "S"
  }
}
```

**`terraform/bootstrap/variables.tf`**:
```hcl
variable "aws_region" {
  description = "AWSリージョン"
  default     = "ap-northeast-1"
}

variable "project" {
  description = "プロジェクト識別子（命名規則のプレフィックス）"
  default     = "handson"
}

variable "environment" {
  description = "環境識別子"
  default     = "dev"
}
```

**`terraform/bootstrap/outputs.tf`**:
```hcl
output "tfstate_bucket_name" {
  description = "environments/dev/main.tfのbackend設定にコピーして使う"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tflock_table_name" {
  description = "environments/dev/main.tfのbackend設定にコピーして使う"
  value       = aws_dynamodb_table.tflock.name
}
```

---

## Task 1-4: Phase 1完了の確認チェックリスト

以下の内容で `docs/phase1-checklist.md` を作成してください。

```markdown
# Phase 1 完了チェックリスト

## 設計思想の言語化
- [ ] TerraformとAnsibleの責務分界を自分の言葉で説明できる
- [ ] 「Immutable Infrastructure」と「Configuration Management」の違いを実例で説明できる
- [ ] terraform stateが「何を知っているか」を3点で説明できる

## 実装確認
- [ ] bootstrap/main.tfが構文エラーなく通る（terraform validate）
- [ ] S3バケットとDynamoDBテーブルが作成される（terraform apply）
- [ ] stateのバージョニングが有効になっている（AWSコンソールで確認）

## 深掘り質問（自己評価）
1. なぜDynamoDBのbilling_modeをPAY_PER_REQUESTにしたのか？
2. prevent_destroyをbootstrapだけに設定している理由は？
3. S3バケットの暗号化が必要な理由は何が保存されているから？
```

---

## Phase 1 実行コマンド

```bash
# ブートストラップの実行
cd terraform/bootstrap
terraform init
terraform validate
terraform plan
terraform apply

# 出力値を控えておく（Phase 2のbackend設定で使用）
terraform output
```

## Phase 2への引き継ぎ情報

Phase 2開始時に以下を確認すること:
- tfstate_bucket_name: `terraform output tfstate_bucket_name`
- tflock_table_name: `terraform output tflock_table_name`