# ✅Phase2: EC2 + ALB + Bastion + IAM

## Phaseサマリー（前Phaseの状態）
Phase1完了済み:
- S3 + DynamoDB remote backend が稼働中
- VPC (10.0.0.0/16) + 6 Subnets (Public×2 / Private×2 / DB×2) が作成済み
- terraform/modules/vpc/ にVPCモジュールが存在する
- terraform/environments/dev/ がベースディレクトリ

## このPhaseの目的
セキュリティグループ、IAM Role (SSM対応)、Bastion EC2、
App EC2 × 2、ALBを構築してFlaskアプリへのルーティングを完成させる。

---

## CLAUDE.mdの参照

CLAUDE.mdを必ず読み込み、以下を再確認すること:
- インスタンスタイプ・AMI設計（arm64 / Graviton）
- IMDSv2強制設定
- Session Manager接続（SSH不要）
- SG最小権限設計

---

## Task 1: Security Groupsモジュール

`terraform/modules/security_groups/main.tf` に以下を作成:

### ALB SG (`tap-dev-alb-sg`)
- inbound: 80/tcp, 443/tcp from `0.0.0.0/0` （インターネット公開）
- outbound: all

### App SG (`tap-dev-app-sg`)
- inbound: 80/tcp from ALB SGのみ（CIDRではなくSG参照で指定）
- inbound: 443/tcp from ALB SG
- outbound: all（パッケージ取得のためNAT経由アウトバウンド許可）

### Bastion SG (`tap-dev-bastion-sg`)
- inbound: **なし**（SSMセッションのみ使用するためインバウンド不要）
- outbound: all

**重要**: `0.0.0.0/0` の22番ポートは絶対に開けない

### variables.tf
```hcl
variable "project"     { type = string }
variable "environment" { type = string }
variable "vpc_id"      { type = string }
```

### outputs.tf
- alb_sg_id
- app_sg_id
- bastion_sg_id

---

## Task 2: IAM Roleモジュール（EC2用）

`terraform/modules/ec2/` 内に IAM関連リソースを作成:

### App EC2用 IAM Role (`tap-dev-ec2-role`)
以下のAWS管理ポリシーをアタッチ:
- `AmazonSSMManagedInstanceCore` （Session Manager接続に必須）
- `CloudWatchAgentServerPolicy` （Phase5の監視用に先行付与）

### Instance Profile
- `tap-dev-ec2-instance-profile`
- 上記Roleをアタッチ

### Bastion EC2用 IAM Role (`tap-dev-bastion-role`)
- `AmazonSSMManagedInstanceCore` のみアタッチ

---

## Task 3: EC2モジュール

`terraform/modules/ec2/main.tf` に以下を実装:

### AMIデータソース
```hcl
# Amazon Linux 2023 (arm64) 最新AMIを動的取得
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
```

### App EC2 × 2台
- instance_type: `t4g.small`
- subnet_id: private_subnet_ids[0], private_subnet_ids[1]（各AZに1台）
- iam_instance_profile: Task2で作成したInstance Profile
- associate_public_ip_address: **false**（Privateサブネットのため）
- user_data: SSM Agentが起動済みであることを確認するスクリプト
- metadata_options:
  ```hcl
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2強制
    http_put_response_hop_limit = 1
  }
  ```
- root_block_device: gp3, 20GB, 暗号化有効

### Bastion EC2 × 1台
- instance_type: `t4g.micro`
- subnet_id: public_subnet_ids[0]
- associate_public_ip_address: true（SSMのPublicエンドポイントへの疎通確認用）
- IMDSv2設定: App EC2と同様
- Bastion専用Instance Profileをアタッチ

### variables.tf に定義すべき変数
```hcl
variable "project"              { type = string }
variable "environment"          { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "public_subnet_ids"    { type = list(string) }
variable "app_sg_id"            { type = string }
variable "bastion_sg_id"        { type = string }
variable "instance_type_app"    { type = string, default = "t4g.small" }
variable "instance_type_bastion"{ type = string, default = "t4g.micro" }
```

### outputs.tf
- app_instance_ids (list)
- app_private_ips (list)
- bastion_instance_id
- bastion_public_ip

---

## Task 4: ALBモジュール

`terraform/modules/alb/main.tf` に以下を実装:

### ALB本体
- internal: false（インターネット向け）
- load_balancer_type: `application`
- subnets: public_subnet_ids (2AZ)
- security_groups: alb_sg_id

### Target Group
- name: `tap-dev-app-tg`
- port: 80
- protocol: HTTP
- target_type: `instance`
- vpc_id: vpc_id
- health_check:
  ```hcl
  health_check {
    path                = "/api/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 10
  }
  ```

### Listener (HTTP:80)
- default_action: forward to target group

### Target Group Attachment
- App EC2 2台をTarget Groupに登録（for_each使用）

### outputs.tf
- alb_dns_name
- target_group_arn

---

## Task 5: environments/dev/main.tf の更新

Phase1のVPCモジュール呼び出しに加えて、以下のモジュールブロックを追加:

```hcl
module "security_groups" {
  source      = "../../modules/security_groups"
  project     = var.project
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
}

module "ec2" {
  source               = "../../modules/ec2"
  project              = var.project
  environment          = var.environment
  private_subnet_ids   = module.vpc.private_subnet_ids
  public_subnet_ids    = module.vpc.public_subnet_ids
  app_sg_id            = module.security_groups.app_sg_id
  bastion_sg_id        = module.security_groups.bastion_sg_id
}

module "alb" {
  source            = "../../modules/alb"
  project           = var.project
  environment       = var.environment
  vpc_id            = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id         = module.security_groups.alb_sg_id
  app_instance_ids  = module.ec2.app_instance_ids
}
```

---

## Task 6: 動作確認

```bash
cd terraform/environments/dev
terraform plan -out=tfplan
terraform apply tfplan

# SSMでApp EC2に接続確認
aws ssm start-session --target <app_instance_id>

# ALB DNSを確認
terraform output alb_dns_name
# → ブラウザでアクセス（まだFlaskは未インストールなので503が正常）
```

---

## 完了基準

- [ ] EC2 3台がRunning状態
- [ ] SSMセッションでApp EC2に接続できる
- [ ] ALBが作成されDNSが払い出されている
- [ ] Target Groupのヘルスチェックが（初期は）unhealthyであること（Flask未インストール）
- [ ] App EC2にPublicIPが付いていないこと
- [ ] `curl http://169.254.169.254/latest/meta-data/` がApp EC2内で**失敗**すること（IMDSv2確認）
- [ ] `TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"); curl -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-id` が**成功**すること

---

## 日本語インラインコメント要件

```hcl
# IMDSv2強制設定 - v1はセキュリティリスクがあるため必ず required に設定
metadata_options {
  http_tokens = "required"
}
```
のように、セキュリティ設計の意図をコメントで明示すること。