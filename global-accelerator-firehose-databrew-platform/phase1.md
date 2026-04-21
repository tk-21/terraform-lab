# ✅Phase 1: ネットワーク基盤・S3・IAM の構築

## このフェーズの概要

プロジェクト全体の土台を作成する。
- Terraform ルート設定・変数・ローカル値
- VPC / サブネット / セキュリティグループ
- S3バケット（Raw / Processed / Athena結果）
- IAMロール（Firehose / Lambda Receiver / Lambda Generator / DataBrew / GitHub Actions OIDC）

## 前提

CLAUDE.mdを最初に読み込むこと。
プロジェクトルート: `global-accelerator-firehose-databrew-platform/`

---

## タスク一覧

### 1. Terraform ルート設定

`terraform/main.tf` を作成する。

```hcl
# 要件:
# - terraform required_version >= 1.6
# - required_providers: aws >= 5.0
# - backend "s3": バケット・キーはvariables.tfから参照（コメントでplaceholder明示）
# - provider "aws": region = var.aws_region, default_tags = local.common_tags
```

`terraform/variables.tf` を作成する。

```
# 定義する変数:
# - project_name: default = "gaf"
# - environment: default = "dev"
# - aws_region: default = "ap-northeast-1"
# - aws_account_id: description付き
# - backend_bucket: Terraform stateバケット名
# - backend_key: default = "gaf/terraform.tfstate"
```

`terraform/locals.tf` を作成する。

```
# 定義:
# - common_tags: CLAUDE.mdのタグ戦略に従う
# - name_prefix: "${var.project_name}-${var.environment}"
#   ※ environmentがdevの場合は "gaf-dev"、prodなら "gaf-prod"
```

`terraform/outputs.tf` を作成する（Phase 1で出力可能な値を記述。後フェーズで追記）。

---

### 2. networking モジュール

`terraform/modules/networking/main.tf` を作成する。

```
# [VPC]
# - CIDR: 10.0.0.0/16
# - DNS解決・DNSホスト名を有効化
#
# [パブリックサブネット × 2]
# - AZ: ap-northeast-1a (10.0.1.0/24), ap-northeast-1c (10.0.2.0/24)
# - ALB を配置するため MapPublicIpOnLaunch = true
#
# [プライベートサブネット × 2]
# - AZ: ap-northeast-1a (10.0.11.0/24), ap-northeast-1c (10.0.12.0/24)
# - Lambda Receiver を配置
#
# [Internet Gateway + パブリックルートテーブル]
# [NAT Gateway × 1（コスト最適化）+ プライベートルートテーブル]
#
# [セキュリティグループ]
#
# sg_alb: ALB用
#   ingress: TCP 443 from 0.0.0.0/0（Global Acceleratorからの通信）
#   ingress: TCP 80 from 0.0.0.0/0（HTTP→HTTPSリダイレクト用）
#   egress: all
#   # 日本語コメント: Global AcceleratorはAWSネットワーク内経由でALBに到達するため
#   # ALBのSGはインターネット全体からの443を許可する必要がある
#
# sg_lambda_receiver: Lambda Receiver用
#   ingress: TCP 443 from sg_alb（ALBからのヘルスチェック・トラフィック）
#   egress: HTTPS to 0.0.0.0/0（Firehose・CloudWatch・VPCエンドポイント向け）
#   # 日本語コメント: LambdaはALBのターゲットとして動作するためSGでALBからの通信を許可
#
# sg_lambda_generator: Lambda Generator用
#   egress: HTTPS to 0.0.0.0/0（Global AcceleratorへのHTTPS送信）
#   # 日本語コメント: GeneratorはVPC外のGlobal AcceleratorエンドポイントにHTTPS送信
```

---

### 3. S3 モジュール

`terraform/modules/s3/main.tf` を作成する。

```
# [1] Raw バケット（Firehose出力先）
# bucket名: "${var.name_prefix}-raw-${var.aws_account_id}"
# - バージョニング: 有効
# - 暗号化: SSE-S3
# - パブリックアクセス: 全ブロック
# - ライフサイクル: 60日後にS3-IA移行、180日後に削除
# - 強制削除: true
# # 日本語コメント: Firehoseが直接書き込む生ログバケット
# # NDJSON形式でyear/month/day/hourパーティションに保存される
#
# [2] Processed バケット（DataBrew出力先）
# bucket名: "${var.name_prefix}-processed-${var.aws_account_id}"
# - バージョニング: 有効
# - 暗号化: SSE-S3
# - パブリックアクセス: 全ブロック
# - ライフサイクル: 90日後にS3-IA、365日後に削除
# - 強制削除: true
# # 日本語コメント: DataBrewが変換・クレンジング後のParquetファイルを出力
#
# [3] Athena 結果バケット
# bucket名: "${var.name_prefix}-athena-results-${var.aws_account_id}"
# - 暗号化: SSE-S3
# - パブリックアクセス: 全ブロック
# - ライフサイクル: 7日後に削除（クエリ結果は短命）
# - 強制削除: true
```

---

### 4. IAM モジュール

`terraform/modules/iam/main.tf` を作成する。

```
# [1] Kinesis Data Firehose 実行ロール: gaf-firehose-role
# 信頼ポリシー: firehose.amazonaws.com
# インラインポリシー:
#   - S3書き込み: s3:PutObject, s3:GetObject, s3:ListBucket
#     Resource: Raw バケット/*
#   - S3エラーレコード書き込み: 同上（エラー用プレフィックス）
#   - CloudWatch Logs（Firehoseのエラーログ）
# # 日本語コメント: FirehoseはS3への書き込みと配信エラー時のログ出力のみ許可
#
# [2] Lambda Receiver 実行ロール: gaf-receiver-role
# 信頼ポリシー: lambda.amazonaws.com
# インラインポリシー:
#   - Firehose書き込み: firehose:PutRecord, firehose:PutRecordBatch
#     Resource: 配信ストリームのARN
#   - CloudWatch Logs + VPC接続用 ec2:CreateNetworkInterface 等
# # 日本語コメント: ReceiverはFirehoseへのPutのみ許可。S3への直接書き込みは禁止
#
# [3] Lambda Generator 実行ロール: gaf-generator-role
# 信頼ポリシー: lambda.amazonaws.com
# インラインポリシー:
#   - CloudWatch Logs のみ
#   - VPC接続用 ec2:* (NetworkInterface系)
# # 日本語コメント: GeneratorはHTTPリクエストを外部送信するだけなのでAWSリソース操作権限は不要
#
# [4] Glue DataBrew 実行ロール: gaf-databrew-role
# 信頼ポリシー: databrew.amazonaws.com
# AWSマネージドポリシー: AWSGlueDataBrewServiceRole
# インラインポリシー（追加）:
#   - Raw バケット読み込み: s3:GetObject, s3:ListBucket
#   - Processed バケット書き込み: s3:PutObject, s3:DeleteObject, s3:ListBucket
#   - Glue Data Catalog: glue:GetDatabase, glue:GetTable, glue:CreateTable 等
# # 日本語コメント: DataBrewジョブはS3の読み書きとGlueカタログ操作が必要
#
# [5] EventBridge Scheduler 実行ロール: gaf-scheduler-role
# 信頼ポリシー: scheduler.amazonaws.com
# インラインポリシー:
#   - lambda:InvokeFunction（Generator関数のみ）
#
# [6] GitHub Actions OIDC ロール: gaf-github-actions-role
# 信頼ポリシー: token.actions.githubusercontent.com (OIDC)
# 条件: repo:takuya/global-accelerator-firehose-databrew-platform:*
# インラインポリシー: Terraform plan/apply に必要な最小権限
# # 日本語コメント: アクセスキー不使用。OIDCで一時クレデンシャルを取得
```

---

### 5. ルートモジュール呼び出し

`terraform/main.tf` にモジュール呼び出しを追記する。

```hcl
# module "networking": VPC・サブネット・SG
# module "s3": 3バケット作成、name_prefix と aws_account_id を渡す
# module "iam": S3バケットARNを渡してポリシーにバインド
```

---

## 完了条件

- [ ] `terraform validate` がエラーなく通る
- [ ] `terraform fmt -recursive` で差分なし
- [ ] 全リソースに `local.common_tags` が付与されている
- [ ] S3バケット3つが作成され、パブリックアクセスが全ブロックになっている
- [ ] IAMロールに AdministratorAccess・iam:* が含まれていない
- [ ] セキュリティグループのインバウンドが必要最小限になっている