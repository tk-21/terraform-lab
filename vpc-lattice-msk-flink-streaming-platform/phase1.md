# ✅Phase 1: ネットワーク基盤・S3・IAM の構築

## このフェーズの概要

プロジェクト全体の土台となるリソースを作成する。
- VPC / サブネット / セキュリティグループ
- S3バケット（Flink出力先 + Flinkアプリ格納用）
- IAMロール（Flink用・Lambda用・GitHub Actions OIDC用）

## 前提確認

CLAUDE.md を必ず最初に読み込むこと。
プロジェクトルート: `vpc-lattice-msk-flink-streaming-platform/`

---

## タスク一覧

### 1. Terraformルート設定ファイルの作成

`terraform/main.tf` を作成する。

```hcl
# 要件:
# - terraform required_version: >= 1.6
# - required_providers: aws >= 5.0
# - backend: S3（バケット名・キーはvariables.tfで定義、コメントでplaceholderを示す）
# - provider "aws": region = var.aws_region, default_tags = local.common_tags
```

`terraform/variables.tf` を作成する。

```
# 以下の変数を定義:
# - project_name: default = "streaming"
# - environment: default = "dev"
# - aws_region: default = "ap-northeast-1"
# - aws_account_id: description付き、sensitive = false
# - backend_bucket: Terraform stateバケット名
# - backend_key: default = "vpc-lattice-msk-flink/terraform.tfstate"
```

`terraform/locals.tf` を作成する。

```
# 以下を定義:
# - common_tags: CLAUDE.mdのタグ戦略に従う
# - name_prefix: "${var.project_name}-${var.environment}" 形式
```

`terraform/outputs.tf` を作成する（Phase 1で出力可能な値を定義。後のフェーズで追記）

---

### 2. networkingモジュールの作成

`terraform/modules/networking/main.tf` を作成する。

```
# 作成リソース:
# [VPC]
# - CIDRブロック: 10.0.0.0/16
# - DNS解決・DNSホスト名を有効化（MSK接続に必須）
# - タグ: Name = "${var.name_prefix}-vpc"
#
# [サブネット]
# - プライベートサブネット x 2（AZ: ap-northeast-1a, ap-northeast-1c）
#   CIDR: 10.0.1.0/24, 10.0.2.0/24
#   MSK・Flinkを配置
# - パブリックサブネット x 2（AZ: ap-northeast-1a, ap-northeast-1c）
#   CIDR: 10.0.101.0/24, 10.0.102.0/24
#   NAT Gateway配置用
#
# [NAT Gateway]
# - EIP x 1（シングルNAT、コスト最適化）
# - パブリックサブネットに配置
#
# [ルートテーブル]
# - パブリック用: Internet Gateway向け
# - プライベート用: NAT Gateway向け
#
# [セキュリティグループ]
# sg_msk: MSK用
#   ingress: TCP 9098（IAM認証ポート）from sg_lambda, sg_flink
#   egress: all
# sg_lambda: Lambda Producer用
#   egress: TCP 9098 to sg_msk, HTTPS to 0.0.0.0/0（Lambda Powertoolsログ送信）
#   # 日本語コメント: Lambda ProducerはMSKへの書き込みとCloudWatchへのログ送信が必要
# sg_flink: Flink用
#   ingress: TCP 8081（Flink UI）from 10.0.0.0/16
#   egress: TCP 9098 to sg_msk, HTTPS to 0.0.0.0/0
#   # 日本語コメント: FlinkはMSKからの読み込みとS3への書き込みが必要
# sg_vpc_lattice: VPC Latticeエンドポイント用
#   ingress: HTTPS from 10.0.0.0/16
#   egress: TCP 9098 to sg_msk
```

---

### 3. S3モジュールの作成

`terraform/modules/s3/main.tf` を作成する。

```
# 作成リソース:
#
# [1] Flinkイベント出力バケット
# bucket名: "${var.name_prefix}-output-${var.aws_account_id}"
# - バージョニング: 有効
# - 暗号化: SSE-S3（AES256）
# - パブリックアクセス: 全ブロック
# - ライフサイクル: 90日後にS3 IA移行、365日後に削除
# - 強制削除: true（ハンズオン後のterraform destroyを容易にする）
#
# [2] Flinkアプリ格納バケット（JARファイル置き場）
# bucket名: "${var.name_prefix}-flink-app-${var.aws_account_id}"
# - 暗号化: SSE-S3
# - パブリックアクセス: 全ブロック
# - バージョニング: 有効（Flinkアプリのロールバック対応）
# # 日本語コメント: Flinkアプリケーションのバージョン管理のためバージョニングを有効化
```

---

### 4. IAMロールの作成

`terraform/modules/iam/` ディレクトリを作成し、以下のファイルを作成する。

`terraform/modules/iam/main.tf`:

```
# [1] Flink実行ロール: streaming-flink-role
# 信頼ポリシー: firehose.amazonaws.com（Managed Flinkはdelivery.kinesis扱い）
# ★ 正確には kinesisanalytics.amazonaws.com が信頼エンティティ
# 付与ポリシー（インラインポリシー）:
#   - MSK Kafkaからの読み込み: kafka-cluster:Connect, kafka:DescribeCluster,
#     kafka-cluster:ReadData, kafka-cluster:DescribeTopic（MSK IAM認証）
#   - S3書き込み: s3:PutObject, s3:GetObject, s3:ListBucket
#     Resource: flinkアプリバケット + 出力バケット
#   - CloudWatch Logs書き込み（Flinkログ）
#   - VPC接続用: ec2:CreateNetworkInterface, ec2:DescribeNetworkInterfaces,
#     ec2:DeleteNetworkInterface, ec2:DescribeSubnets,
#     ec2:DescribeSecurityGroups, ec2:DescribeVpcs
#   # 日本語コメント: FlinkのVPC内実行にはENI作成権限が必要
#
# [2] Lambda Producer実行ロール: streaming-producer-role
# 信頼ポリシー: lambda.amazonaws.com
# 付与ポリシー（インラインポリシー）:
#   - MSK Kafkaへの書き込み: kafka-cluster:Connect, kafka:DescribeCluster,
#     kafka-cluster:WriteData, kafka-cluster:DescribeTopic
#   - CloudWatch Logs（AWSLambdaVPCAccessExecutionRole相当）
#   - VPC接続用: ec2:CreateNetworkInterface, ec2:DescribeNetworkInterfaces,
#     ec2:DeleteNetworkInterface
#   # 日本語コメント: Lambda ProducerはMSK書き込みのみ許可。読み込み権限は付与しない（最小権限）
#   # 禁止: iam:PassRole, iam:PutRolePolicy などIAM操作権限は一切付与しない
#
# [3] GitHub Actions OIDC用ロール（CI/CDパイプライン用）
# 信頼ポリシー: oidc.provider（GitHub ActionsのOIDCプロバイダー）
# - プロバイダーURL: token.actions.githubusercontent.com
# - Audience: sts.amazonaws.com
# - 条件: リポジトリ = "takuya/vpc-lattice-msk-flink-streaming-platform"
# 付与権限:
#   - terraform plan/apply に必要な最小権限
#   - S3（stateバケット）: GetObject, PutObject, DeleteObject, ListBucket
#   - DynamoDB（stateロック）: GetItem, PutItem, DeleteItem（オプション）
#   # 日本語コメント: GitHub ActionsはOIDCで一時クレデンシャルを取得。アクセスキー不使用
```

---

### 5. ルートモジュールからの呼び出し

`terraform/main.tf` にモジュール呼び出しを追記する。

```hcl
# module "networking" を呼び出す
# module "s3" を呼び出す（networking後）
# module "iam" を呼び出す（s3後、S3バケットARNを渡す）
```

---

### 6. 動作確認コマンド

全ファイル作成後、以下のコメントをREADMEに記載すること：

```bash
cd terraform
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var="aws_account_id=YOUR_ACCOUNT_ID"
```

---

## 完了条件

- [ ] `terraform validate` がエラーなく通る
- [ ] `terraform fmt -recursive` で差分なし
- [ ] 全ファイルにCLAUDE.mdの命名規則が適用されている
- [ ] 全リソースに `var.common_tags` または `local.common_tags` が付与されている
- [ ] IAMロールに過剰な権限（iam:*、AdministratorAccess等）が含まれていない
- [ ] セキュリティグループにインバウンド 0.0.0.0/0 が含まれていない（sg_lambdaのegressは除く）