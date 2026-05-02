# ✅Phase 2: セキュリティ層 + コンピュート層

## Phase 1 で生成済みのもの（このフェーズの前提）
- terraform/modules/network/ (VPC, Subnet, NACL, Flow Logs)
- terraform/envs/prod/main.tf (network モジュール呼び出し済み)
- outputs: vpc_id, public_subnet_ids, private_subnet_ids, data_subnet_ids

---

## このフェーズで実装するもの
1. KMS カスタマーキー (CMK)
2. Secrets Manager (RDS パスワード)
3. IAM ロール・インスタンスプロファイル
4. セキュリティグループ (ALB / EC2 / RDS)
5. ALB (Application Load Balancer)
6. Launch Template + Auto Scaling Group

---

## Step 1: secrets モジュール

`terraform/modules/secrets/` を作成。

### KMS CMK

```
要件:
- キーエイリアス: alias/s3t-prod-main
- キーポリシー（上級）:
  - ルートアカウントに完全な管理権限（キーが孤立しないための必須設定）
  - EC2インスタンスロールに: kms:Decrypt, kms:GenerateDataKey のみ許可
  - CloudWatch Logs サービスプリンシパルに encrypt/decrypt 許可
  - [セキュリティ] kms:* の全許可は避ける。用途ごとに最小権限
- key_usage: ENCRYPT_DECRYPT
- enable_key_rotation: true  ← [セキュリティ] 年次自動ローテーション
- deletion_window_in_days: 30
- lifecycle { prevent_destroy = true }  ← [注意] 削除するとEBS/RDSデータが永久に失われる
```

### Secrets Manager

```
要件:
- シークレット名: ata-prod/rds/master-password
- 初期値: Terraform の random_password リソースで自動生成
  - length: 32, special: true, override_special: "!#$%&*()-_=+[]{}<>:?"
- KMS CMK で暗号化
- 自動ローテーション設定:
  - rotation_rules: automatically_after_days = 30
  - [注意] ローテーション Lambda は Phase 3 (RDS構築後) に接続する。
           このフェーズでは Lambda ARN なしで設定し、Phase 3 で aws_secretsmanager_secret_rotation を追加
- outputs: secret_arn, secret_name (DB接続文字列構築用)
```

---

## Step 2: security モジュール

`terraform/modules/security/` を作成。

### IAM ロール設計（上級要件）

```
EC2用インスタンスロール: s3t-prod-ec2-role

信頼ポリシー:
- ec2.amazonaws.com のみ（サービスリンクロール）

インラインポリシー (最小権限):
1. SSM Session Manager用:
   - ssm:UpdateInstanceInformation
   - ssmmessages:CreateControlChannel
   - ssmmessages:CreateDataChannel
   - ssmmessages:OpenControlChannel
   - ssmmessages:OpenDataChannel
   - s3:GetEncryptionConfiguration  ← Session Managerのログ暗号化確認用
   [セキュリティ] SSM:* は与えない。Parameter Store アクセスは別ポリシーで分離

2. Secrets Manager用:
   - secretsmanager:GetSecretValue
   - Resource: ata-prod/rds/* のみ
   - [セキュリティ] SecretStringのGetのみ。RotateSecret等は不可

3. CloudWatch Agent用:
   - AmazonCloudWatchFullAccess は使わない
   - 必要なアクション: cloudwatch:PutMetricData, logs:CreateLogStream, 
     logs:PutLogEvents, logs:DescribeLogGroups, logs:DescribeLogStreams

4. KMS用:
   - kms:Decrypt, kms:GenerateDataKey
   - Resource: KMS CMK ARN のみ

5. S3 (Session Managerログ用):
   - s3:PutObject
   - Resource: s3t-prod-session-logs-{account_id}/sessions/* のみ

マネージドポリシー追加:
- AmazonSSMManagedInstanceCore  ← SSMエージェント動作に必要

インスタンスプロファイル: s3t-prod-ec2-profile
```

### セキュリティグループ設計

```
1. ALB セキュリティグループ: s3t-prod-alb-sg
   インバウンド:
   - 443/tcp: 0.0.0.0/0, ::/0  (HTTPS)
   - 80/tcp: 0.0.0.0/0, ::/0   (HTTPSリダイレクト用)
   アウトバウンド:
   - EC2 SG へのポート8080のみ  ← [設計意図] ALBからEC2へのトラフィックを最小化

2. EC2 セキュリティグループ: s3t-prod-web-sg
   インバウンド:
   - 8080/tcp: source = ALB SG のみ  ← [セキュリティ] IPではなくSG参照で動的に対応
   アウトバウンド:
   - 443/tcp: 0.0.0.0/0  (Secrets Manager, SSM, ECR等のAWS API)
   - 3306/tcp: RDS SG へのみ
   [セキュリティ] SSHポート(22)は一切開放しない。SSM Session Managerを使用

3. RDS セキュリティグループ: s3t-prod-rds-sg
   インバウンド:
   - 3306/tcp: source = EC2 SG のみ
   アウトバウンド: なし（ステートフルなので応答パケットは自動で通る）
   [セキュリティ] DB層はインターネットから2段階隔離（NATなし + SG制限）
```

---

## Step 3: compute モジュール (ALB)

`terraform/modules/compute/alb.tf` を作成。

```
要件:
- ALB: s3t-prod-alb (internal = false, public subnet配置)
- HTTPリスナー(80): HTTPSへ301リダイレクト
- HTTPSリスナー(443):
  - デフォルトアクション: ターゲットグループへ転送
  - SSL Policy: ELBSecurityPolicy-TLS13-1-2-2021-06  ← [セキュリティ] TLS 1.3推奨
  - 証明書: ACM (certificate_arn は variable で受け取る。ハンズオンでは自己署名でも可)
- ターゲットグループ: s3t-prod-web-tg
  - protocol: HTTP, port: 8080
  - health_check: path="/health", interval=30, healthy_threshold=2, unhealthy_threshold=3
  - deregistration_delay: 30  ← [設計意図] ドレイン時間。本番は300秒が多いが検証は短く
- アクセスログ:
  - S3バケット: s3t-prod-alb-logs-{account_id}
  - prefix: alb/
  - [セキュリティ] アクセスログは監査証跡として必須
```

---

## Step 4: compute モジュール (Launch Template + ASG)

`terraform/modules/compute/asg.tf` を作成。

### Launch Template（上級要件）

```
要件:
- 名前: s3t-prod-web-lt
- AMI: Amazon Linux 2023 (SSM Parameter /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64)
  arm64アーキテクチャ使用  ← [コスト] x86_64比で最大20%コスト削減
- instance_type: t4g.small (arm64)
- IAMインスタンスプロファイル: s3t-prod-ec2-profile
- ネットワーク: private subnet, SG = EC2 SG, パブリックIP割り当てなし
- EBS:
  - ルートボリューム: gp3, 20GB, 暗号化=true, KMS CMK指定
  - delete_on_termination: true
- IMDSv2 強制（上級ポイント）:
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   ← IMDSv1を無効化
    http_put_response_hop_limit = 1            ← コンテナからのIMDS到達を防ぐ
    instance_metadata_tags      = "enabled"    ← タグもIMDSv2経由で取得可能に
  }
  [セキュリティ] IMDSv1はSSRF攻撃でクレデンシャル漏洩するリスクがある
- user_data (Base64エンコード):
  #!/bin/bash
  # CloudWatch Agentのインストール（Ansibleで後から設定するが初期インストールはここで）
  dnf install -y amazon-cloudwatch-agent
  # SSMエージェントの確認（AL2023はデフォルトインストール済みだが念のため）
  systemctl enable amazon-ssm-agent
  systemctl start amazon-ssm-agent
  # Ansibleが後でアプリをデプロイするためのディレクトリ準備
  mkdir -p /opt/app
  chown ec2-user:ec2-user /opt/app
```

### Auto Scaling Group

```
要件:
- 名前: s3t-prod-web-asg
- min_size: 2, max_size: 6, desired_capacity: 2  ← [設計意図] 最小2台で単一障害点排除
- target_group_arns: ALBのターゲットグループ
- vpc_zone_identifier: private_subnet_ids (3AZ)
- health_check_type: ELB  ← [設計意図] ALBのヘルスチェック結果でASGが判断
- health_check_grace_period: 300
- インスタンスリフレッシュ設定:
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50  ← [設計意図] ローリング更新でダウンタイムなし
      instance_warmup        = 120
    }
  }
- スケーリングポリシー: TargetTrackingScaling
  - CPU使用率60%でスケールアウト
  - [コスト] 70%ではなく60%にすることで応答性を確保しながらコスト抑制
- タグ伝播: Ansible動的インベントリ用タグを必ず伝播
  - Role = "webserver"
  - Environment = "prod"
  - Project = "secure-3tier-iac-pipeline"
```

---

## Step 5: envs/prod/main.tf を更新

Phase 1 の network モジュール呼び出しに加え、以下を追加：
- secrets モジュール呼び出し
- security モジュール呼び出し (vpc_id, subnet_ids を network output から渡す)
- compute モジュール呼び出し (security output のSG IDを渡す)

---

## 完了条件
- [ ] KMS CMK にキーローテーションが有効になっている
- [ ] Secrets Manager シークレットが KMS CMK で暗号化されている
- [ ] EC2 IAM ロールに SSH用ポートを開けるような権限がない
- [ ] Launch Template に `http_tokens = "required"` が設定されている
- [ ] ALB が HTTP→HTTPS リダイレクトを行う設定になっている
- [ ] ASG のタグに `Role = "webserver"` が含まれ、インスタンスに伝播される設定
- [ ] セキュリティグループが IP ではなく SG 参照を使っている
- [ ] `terraform validate` が通る

## 次フェーズへの引き継ぎ情報
Phase 3 で使用する outputs:
- kms_key_arn (RDS暗号化, Secrets Managerローテーション Lambda用)
- rds_secret_arn (RDS接続情報取得用)
- alb_dns_name (動作確認用)
- ec2_security_group_id (RDS SGのインバウンドルール用)
- asg_name (Ansibleの動的インベントリフィルタリング用)