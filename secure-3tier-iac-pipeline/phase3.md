# ✅Phase 3: データ層 (RDS Aurora) + SSM設定 + Terraform仕上げ

## Phase 1-2 で生成済みのもの（このフェーズの前提）
- network モジュール: vpc_id, subnet_ids (public/private/data)
- secrets モジュール: kms_key_arn, rds_secret_arn
- security モジュール: alb_sg_id, web_sg_id, rds_sg_id, ec2_instance_profile
- compute モジュール: alb_arn, target_group_arn, asg_name

---

## このフェーズで実装するもの
1. RDS Aurora MySQL Serverless v2
2. Secrets Manager ローテーション Lambda の接続
3. SSM Session Manager 設定 (セッションログのS3保存)
4. S3バケット群 (ALBログ, Sessionログ, アプリデータ)
5. Terraform 全体の仕上げ (outputs, validation, moved ブロック解説)

---

## Step 1: database モジュール

`terraform/modules/database/` を作成。

### RDS Aurora MySQL Serverless v2（上級要件）

```
クラスター: s3t-prod-aurora-cluster

要件:
- engine: aurora-mysql
- engine_version: 8.0.mysql_aurora.3.04.0  (最新安定版を指定)
- database_name: appdb
- master_username: admin
- manage_master_user_password: false
  ← [設計意図] Secrets Managerと手動統合してローテーションを完全制御
  master_password は aws_secretsmanager_secret_version から data source で取得

- storage_encrypted: true
- kms_key_id: KMS CMK ARN
- deletion_protection: true
  [注意] ハンズオン終了時は false に変更してから destroy
- backup_retention_period: 7
- preferred_backup_window: "17:00-18:00"  ← UTC (JST 02:00-03:00)
- preferred_maintenance_window: "sun:18:00-sun:19:00"  ← UTC (JST 月曜03:00-04:00)
- skip_final_snapshot: false
- final_snapshot_identifier: "s3t-prod-aurora-final-{timestamp}"
- vpc_security_group_ids: [rds_sg_id]
- db_subnet_group_name: s3t-prod-db-subnet-group (data subnetを指定)
- enabled_cloudwatch_logs_exports: ["audit", "error", "slowquery"]
  [セキュリティ] 監査ログをCloudWatch Logsに送信。後でアラート設定可能

Serverless v2 スケーリング設定:
serverlessv2_scaling_configuration {
  min_capacity = 0.5   ← [コスト] 最小0.5 ACU。アイドル時のコスト削減
  max_capacity = 4.0   ← [設計意図] 本番初期は4ACU上限。負荷に応じて引き上げ
}

インスタンス (ライター1台 + リーダー1台):
- ライター: s3t-prod-aurora-writer
  instance_class = "db.serverless"
- リーダー: s3t-prod-aurora-reader
  instance_class = "db.serverless"
  [設計意図] リーダーエンドポイントをアプリの読み取りに使いライターの負荷を下げる

lifecycle {
  prevent_destroy = true  ← [注意] 本番データ保護
  ignore_changes = [master_password]  ← Secrets Managerローテーション後の差分を無視
}

outputs:
- cluster_endpoint (書き込み用)
- reader_endpoint (読み取り用)
- cluster_identifier
- port
```

### Secrets Manager ローテーション接続

```
aws_secretsmanager_secret_rotation リソースを追加:
- secret_id: rds_secret_arn (Phase 2 output)
- rotation_lambda_arn: AWS管理のローテーションLambda
  ※ Aurora MySQL用のAWS管理Lambda: arn:aws:lambda:{region}:{account}:function:SecretsManagerMySQLRotationSingleUser
  [設計意図] カスタムLambdaを作らずAWS管理Lambdaを使うことで運用コストを削減
  [注意] ローテーションLambdaはSM VPCエンドポイントまたはパブリックSMエンドポイントにアクセスできる必要がある

rotation_rules:
  automatically_after_days = 30
  duration = "2h"
  schedule_expression = "rate(30 days)"
```

---

## Step 2: SSM モジュール

`terraform/modules/ssm/` を作成。

### Session Manager セッションログ設定（上級要件）

```
S3バケット: s3t-prod-session-logs-{account_id}
- バージョニング: 有効
- パブリックアクセス: 全ブロック
- サーバーサイド暗号化: KMS CMK
- ライフサイクルルール:
  - 90日後に Glacier Instant Retrieval へ移行  ← [コスト] ログのコスト削減
  - 365日後に削除
- バケットポリシー: SSMサービスプリンシパルからの s3:PutObject を許可
  ConditionでSSL必須 (aws:SecureTransport: true)

SSM ドキュメント (セッション設定):
aws_ssm_document リソースで Session Manager のドキュメント設定:
{
  "schemaVersion": "1.0",
  "description": "Session Manager preferences",
  "sessionType": "Standard_Stream",
  "inputs": {
    "s3BucketName": "s3t-prod-session-logs-{account_id}",
    "s3KeyPrefix": "sessions/",
    "s3EncryptionEnabled": true,
    "cloudWatchLogGroupName": "/aws/ssm/sessions/ata-prod",
    "cloudWatchEncryptionEnabled": true,
    "idleSessionTimeout": "20",      ← [セキュリティ] 20分アイドルで自動切断
    "maxSessionDuration": "60",      ← [セキュリティ] 最大60分
    "kmsKeyId": "{kms_key_arn}"
  }
}
[セキュリティ] セッションログにより「誰が・いつ・何をしたか」を完全追跡可能

SSM Parameter Store:
- /ata-prod/app/db_endpoint: Aurora クラスターエンドポイント (SecureString, KMS CMK)
- /ata-prod/app/db_reader_endpoint: リーダーエンドポイント (SecureString)
- /ata-prod/app/db_port: "3306" (String)
- /ata-prod/app/db_name: "appdb" (String)
[設計意図] アプリはParameter StoreからDB接続情報を取得。
          パスワードはSecrets Managerから別途取得（責務分離）
```

---

## Step 3: S3バケット群

`terraform/modules/compute/s3.tf` に追記（または独立したモジュールとして）

```
1. ALBアクセスログバケット: s3t-prod-alb-logs-{account_id}
   - パブリックアクセス全ブロック
   - SSE-S3 (ALBは KMS CMK 暗号化に非対応のため)
   - バケットポリシー: ALBサービスアカウント (ap-northeast-1: 582318560864) からの PutObject を許可
   - ライフサイクル: 90日で削除

2. アプリデータバケット: s3t-prod-app-data-{account_id}  (静的コンテンツ想定)
   - KMS CMK 暗号化
   - バージョニング有効
   - パブリックアクセス全ブロック
   - CORS設定: ALB ドメインからのアクセスのみ許可
```

---

## Step 4: VPC エンドポイント (Gateway + Interface)

`terraform/modules/network/` に `endpoints.tf` を追加。

```
Gateway型エンドポイント (無料):
- S3: com.amazonaws.ap-northeast-1.s3
  route_table_ids: private + data subnet のルートテーブル
- DynamoDB: com.amazonaws.ap-northeast-1.dynamodb

Interface型エンドポイント (有料だが必要):
以下はNAT Gatewayなしでプライベートサブネットからアクセスするために必要:
- SSM: com.amazonaws.ap-northeast-1.ssm
- SSM Messages: com.amazonaws.ap-northeast-1.ssmmessages
- EC2 Messages: com.amazonaws.ap-northeast-1.ec2messages
- Secrets Manager: com.amazonaws.ap-northeast-1.secretsmanager
- CloudWatch Logs: com.amazonaws.ap-northeast-1.logs
- KMS: com.amazonaws.ap-northeast-1.kms

Interface型の共通設定:
- subnet_ids: private_subnet_ids
- security_group_ids: VPCエンドポイント専用SG (EC2 SG からの 443 を許可)
- private_dns_enabled: true  ← [設計意図] エンドポイントURLの変更不要

[コスト] Interface型は1エンドポイントあたり ~$7.5/月。
         NAT Gatewayは ~$45/月 + データ転送料 なのでSSM/SM/KMS用途ならエンドポイントの方が安い
```

---

## Step 5: Terraform 全体の仕上げ

### terraform.tfvars (envs/prod/)

```hcl
environment    = "prod"
owner          = "platform-team"
aws_account_id = "YOUR_ACCOUNT_ID"  # 要変更

# ALB証明書 (ハンズオンでは空でも可。HTTPSリスナーをHTTPに変更する分岐を variable で制御)
acm_certificate_arn = ""
enable_https        = false  # ハンズオン用: trueにするとACM証明書が必要
```

### variable validation の追加

```hcl
# variables.tf に追加
variable "environment" {
  validation {
    condition     = contains(["prod", "stg", "dev"], var.environment)
    error_message = "environment は prod, stg, dev のいずれかである必要があります。"
  }
}
```

### terraform/envs/prod/outputs.tf の完成

全モジュールの重要 output をまとめて出力:
- alb_dns_name (動作確認URL)
- aurora_cluster_endpoint
- aurora_reader_endpoint
- session_log_bucket_name
- kms_key_arn
- ssm_connect_command: "aws ssm start-session --target {instance_id} --region ap-northeast-1"

### versions.tf を追加

```hcl
terraform {
  required_version = ">= 1.7.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0, < 6.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}
```

---

## 完了条件
- [ ] RDS Aurora Serverless v2 が data subnet に配置される設定
- [ ] `deletion_protection = true` と `prevent_destroy = true` が設定されている
- [ ] Secrets Manager ローテーションが設定されている
- [ ] Session Manager のセッションが S3 に記録される設定
- [ ] VPC エンドポイントにより EC2 から SSH なしで AWS API にアクセスできる構成
- [ ] `terraform validate` が通る
- [ ] S3バケットに `aws:SecureTransport` ポリシーが設定されている

## 次フェーズへの引き継ぎ情報
Phase 4 (Ansible) で使用する情報:
- ASG名: s3t-prod-web-asg (動的インベントリのフィルタリングに使用)
- EC2タグ: Role=webserver, Project=secure-3tier-iac-pipeline, Environment=prod
- 接続方式: SSM Session Manager (ansible_connection: aws_ssm)
- アプリディレクトリ: /opt/app (user_dataで作成済み)
- SSM Parameter Store パス: /ata-prod/app/
- Secrets Manager シークレット名: ata-prod/rds/master-password