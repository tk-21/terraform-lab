---
name: terraform-module
description: Terraformモジュールの設計・実装・レビューを行う際に使用するスキル。モジュール構造、命名規則、IAM設計、変数定義、outputs設計など、Takuyaのプロジェクト標準に準拠したTerraformコードを生成する。
---

このスキルは、ポートフォリオ品質のTerraformモジュールを生成するためのガイドラインを定義する。
すべてのコードは「即実用可能・セキュリティ優先・コスト意識あり」の3原則に従う。

## プロジェクト標準

### 基本設定
- **デフォルトリージョン**: `ap-northeast-1` (東京)
- **Terraformバージョン**: `>= 1.5.0`
- **AWSプロバイダーバージョン**: `>= 5.0`
- **tfstate管理**: S3 + DynamoDB (既存backendモジュール参照)
- **認証**: OIDC (アクセスキー使用禁止)

### 命名規則
```
# リソース命名パターン
{prefix}-{service}-{role}-{env}

# 例
tep-lambda-analyzer-prod
sep-iam-role-bedrock
sap-sg-allow-https

# IAMロール名は64文字以内 (AWSハード制限)
# prefix例: tmp / sep / sap / tep / gitops
```

### ディレクトリ構造
```
modules/
  {module-name}/
    main.tf          # メインリソース定義
    variables.tf     # 入力変数
    outputs.tf       # 出力値
    versions.tf      # プロバイダーバージョン制約
    iam.tf           # IAMリソース (分離推奨)
    locals.tf        # ローカル変数 (命名計算など)
    README.md        # モジュール説明 (terraform-docs形式)

environments/
  {env}/
    main.tf
    terraform.tfvars
    backend.tf
```

## IAM設計原則

### 最小権限の徹底
```hcl
# ❌ 禁止: ワイルドカード濫用
resource "aws_iam_role_policy" "bad" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = "bedrock:*"
      Resource = "*"
    }]
  })
}

# ✅ 推奨: アクション・リソースを明示
resource "aws_iam_role_policy" "good" {
  policy = jsonencode({
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream"
      ]
      # モデルARNを明示
      Resource = "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-*"
    }]
  })
}
```

### AI自動化プロジェクトのIAM安全設計
- Lambda実行ロールに `iam:PutRolePolicy` / `iam:AttachRolePolicy` を付与しない
- IAM変更はGitHub PR経由の人間レビューを必須とする
- Bedrockモデル呼び出しは特定モデルARNに限定する

### OIDC設定 (GitHub Actions標準)
```hcl
# ポートフォリオ全プロジェクト共通パターン
resource "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  # 64文字制限に注意
  name = "${var.prefix}-github-actions-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_org}/${var.repo_name}:*"
        }
      }
    }]
  })
}
```

## Lambda モジュール標準

### 必須設定
```hcl
resource "aws_lambda_function" "main" {
  function_name = "${local.name_prefix}-${var.function_name}"
  runtime       = "python3.12"
  architectures = ["arm64"]  # コスト最適化: x86_64より約20%安価
  handler       = "handler.lambda_handler"
  timeout       = var.timeout
  memory_size   = var.memory_size

  # Lambda Powertools Layer (arm64用)
  layers = [
    "arn:aws:lambda:ap-northeast-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-arm64:${var.powertools_layer_version}"
  ]

  environment {
    variables = merge(
      {
        POWERTOOLS_SERVICE_NAME    = var.function_name
        POWERTOOLS_LOG_LEVEL       = var.log_level
        AWS_LAMBDA_LOG_FORMAT      = "JSON"  # 構造化ログ
      },
      var.environment_variables
    )
  }

  tracing_config {
    mode = "Active"  # X-Ray トレーシング有効化
  }
}
```

### Pythonコード標準
```python
# Lambda Powertools必須インポート
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext

# サービス名はTerraformのfunction_nameと一致させる
logger = Logger(service="analyzer")
tracer = Tracer(service="analyzer")
metrics = Metrics(namespace="MyProject")

@tracer.capture_lambda_handler
@logger.inject_lambda_context(log_event=True)
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    # 日本語コメントで設計意図を説明
    # Bedrockへのリクエストを構築する
    pass
```

## Bedrock統合パターン

### モデル選択基準
| ユースケース | モデル | 理由 |
|---|---|---|
| Security Hub トリアージ | Claude Haiku | 速度優先・低コスト |
| コスト異常分析 | Claude Sonnet | 因果推論が必要 |
| IAM最小権限生成 | Claude Sonnet | 精度優先 |
| 定期レポート生成 | Claude Haiku | バッチ処理・コスト重視 |

### Bedrock呼び出しパターン
```hcl
# Bedrockアクセス用IAMポリシー (最小権限)
data "aws_iam_policy_document" "bedrock_invoke" {
  statement {
    effect = "Allow"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-haiku-*",
      "arn:aws:bedrock:ap-northeast-1::foundation-model/anthropic.claude-sonnet-*"
    ]
  }
}
```

## 変数・Output設計

### variables.tf パターン
```hcl
variable "prefix" {
  description = "リソース名プレフィックス (例: tep, sep, sap)"
  type        = string
  validation {
    condition     = length(var.prefix) <= 5
    error_message = "プレフィックスは5文字以内にしてください (IAMロール名64文字制限のため)"
  }
}

variable "tags" {
  description = "全リソースに付与するタグ"
  type        = map(string)
  default     = {}
}
```

### locals.tf パターン
```hcl
locals {
  # 命名計算はlocalsに集約する
  name_prefix = "${var.prefix}-${var.env}"

  # 共通タグはここで合成
  common_tags = merge(var.tags, {
    ManagedBy   = "terraform"
    Project     = var.prefix
    Environment = var.env
  })
}
```

### outputs.tf パターン
```hcl
# 他モジュールから参照されるものは必ずoutput化
output "lambda_function_arn" {
  description = "Lambda関数のARN"
  value       = aws_lambda_function.main.arn
}

output "lambda_role_arn" {
  description = "Lambda実行ロールのARN (クロスモジュール参照用)"
  value       = aws_iam_role.lambda_exec.arn
}
```

## コスト管理

### 月次コスト目安 (プロジェクト標準)
- **目標**: $30/月以下
- Lambda: arm64 + 適切なメモリ設定で最小化
- DynamoDB: On-Demand (開発) / Provisioned (本番で固定負荷時)
- Bedrock: Haiku優先、Sonnetは必要な推論タスクのみ
- Aurora pgvector: t4g.medium (Serverlessより安価な場合)

### コスト可視化タグ戦略
```hcl
# 全リソースに必須タグを付与
tags = {
  Project     = var.prefix
  CostCenter  = var.project_name
  Environment = var.env
  ManagedBy   = "terraform"
}
```

## セキュリティチェックリスト

コード生成後に以下を確認する:
- [ ] IAMロール名が64文字以内
- [ ] `*` アクション・リソースが使われていない
- [ ] S3バケットのパブリックアクセスブロックが有効
- [ ] Lambda環境変数に機密情報を直接書いていない (SSM/Secrets Manager経由)
- [ ] OIDC認証を使用 (アクセスキー不使用)
- [ ] CloudTrailログが有効なリージョン
- [ ] VPCエンドポイント経由でAWSサービスにアクセス (必要な場合)

## ポートフォリオ品質マーカー

すべてのモジュールに以下を含める:
1. **README.md**: アーキテクチャ概要・使い方・コスト見積もり
2. **ADR (Architecture Decision Record)**: 設計判断の理由を記録
3. **日本語コメント**: コードの設計意図を説明 (英語コードに日本語コメント)
4. **`terraform-docs`互換形式**: `## Inputs` / `## Outputs` テーブル

```hcl
# ✅ 日本語コメントの例
resource "aws_dynamodb_table" "dedup" {
  # 重複通知防止用テーブル
  # Security Hub findings はEventBridgeで複数回発火する可能性があるため
  # finding_id をハッシュキーとしてべき等性を保証する
  name         = "${local.name_prefix}-dedup"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "finding_id"

  # TTL: 24時間後に自動削除 (ストレージコスト最小化)
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
}
```