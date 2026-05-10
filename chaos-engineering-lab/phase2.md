# ✅Phase 2 — ALB + ASG + Launch Template

## 前フェーズ（Phase 1）の成果物

Phase 1 で以下が生成済み:
- `terraform/modules/vpc/` — VPC / サブネット / IGW / NAT GW
- `terraform/modules/sg/` — ALB SG / EC2 SG
- `terraform/environments/dev/main.tf` — モジュール骨格（alb / asg はコメントアウト中）
- `terraform/environments/dev/variables.tf` / `outputs.tf` / `versions.tf` / `terraform.tfvars`

## このフェーズのゴール

以下のファイルを生成する:
1. ALB モジュール（ターゲットグループ・リスナー・アクセスログ用 S3）
2. ASG モジュール（Launch Template + Auto Scaling Group + Target Tracking Policy）
3. `environments/dev/main.tf` の alb / asg モジュール呼び出しを有効化

---

## 生成指示

### 1. `terraform/modules/alb/main.tf`

**S3 バケット（アクセスログ用）**:
```
aws_s3_bucket               # cel-alb-logs-{account_id}
aws_s3_bucket_policy        # ALB ログ配信 IAM ポリシー（ELB サービスアカウント）
aws_s3_bucket_lifecycle_configuration  # 30 日後に Glacier、90 日後に削除
```

**ALB 本体**:
```
aws_lb                      # cel-{env}-alb、internal=false、public サブネット配置
                            # access_logs → 上記 S3 バケット
aws_lb_target_group         # cel-{env}-tg、HTTP:80、ヘルスチェック /health
                            # healthy_threshold=2, unhealthy_threshold=3, interval=30
aws_lb_listener             # HTTP:80 → ターゲットグループへ転送
```

> コメント: ALB ELB サービスアカウントはリージョン固定値。ap-northeast-1 は 582318560864。

`terraform/modules/alb/variables.tf`: vpc_id, public_subnet_ids, alb_sg_id, prefix, env, account_id, tags
`terraform/modules/alb/outputs.tf`: alb_arn, alb_dns_name, target_group_arn, alb_sg_id

---

### 2. `terraform/modules/asg/main.tf`

**Launch Template**:
```
aws_launch_template         # cel-{env}-lt
  - name_prefix: "cel-{env}-lt-"
  - image_id: data.aws_ami.al2023.id（最新 Amazon Linux 2023 を data source で取得）
  - instance_type: t3.micro
  - vpc_security_group_ids: [ec2_sg_id]
  - iam_instance_profile: { name = var.instance_profile_name }
  - monitoring: { enabled = true }
  - metadata_options:
      http_tokens = "required"           # IMDSv2 強制（セキュリティ設計）
      http_put_response_hop_limit = 1
  - user_data: base64encode(templatefile("${path.module}/userdata.sh.tpl", {...}))
  - tag_specifications: インスタンスと EBS ボリュームにタグ付与
```

**`terraform/modules/asg/userdata.sh.tpl`**:
```bash
#!/bin/bash
# stress-ng インストール（FIS 実験で CPU 負荷注入に使用）
dnf install -y stress-ng

# SSM Agent は Amazon Linux 2023 にプリインストール済み
# ヘルスチェックエンドポイント用の簡易 HTTP サーバー
dnf install -y python3
cat > /etc/systemd/system/healthcheck.service << 'EOF'
[Unit]
Description=Simple health check HTTP server
After=network.target

[Service]
ExecStart=/usr/bin/python3 -m http.server 80 --directory /var/www/html
Restart=always

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /var/www/html
echo '{"status":"ok","instance":"${instance_id}"}' > /var/www/html/health
systemctl enable healthcheck
systemctl start healthcheck
```

**Auto Scaling Group**:
```
data "aws_ami" "al2023"     # Amazon Linux 2023 最新版フィルタ
                            # filter: name = "al2023-ami-*-x86_64"
                            # owners = ["amazon"]、most_recent = true

aws_autoscaling_group       # cel-{env}-asg
  - min_size: 2、desired_capacity: 2、max_size: 6
  - vpc_zone_identifier: private_subnet_ids（プライベートサブネット配置）
  - target_group_arns: [target_group_arn]
  - health_check_type: "ELB"（ALB ヘルスチェックと連動）
  - health_check_grace_period: 120
  - launch_template: { id = aws_launch_template.main.id, version = "$Latest" }
  - instance_refresh:
      strategy = "Rolling"
      preferences = { min_healthy_percentage = 50 }
  - tag: 各タグを propagate_at_launch = true で付与

aws_autoscaling_policy      # cel-{env}-target-tracking-policy
  - policy_type: "TargetTrackingScaling"
  - target_tracking_configuration:
      predefined_metric_type: ASGAverageCPUUtilization
      target_value: 70.0     # CPU 70% でスケールアウト開始
```

> コメント: FIS で CPU ストレスを注入すると CPUUtilization が急上昇し、
> Target Tracking Policy がスケールアウトをトリガーする。
> これがカオス実験の観測ポイント。

`terraform/modules/asg/variables.tf`: prefix, env, private_subnet_ids, ec2_sg_id, target_group_arn, instance_profile_name, min_size, max_size, desired_capacity, tags
`terraform/modules/asg/outputs.tf`: asg_name, asg_arn, launch_template_id

---

### 3. `terraform/environments/dev/main.tf` 更新

Phase 1 でコメントアウトされていた `module "alb"` と `module "asg"` を有効化:

```hcl
module "alb" {
  source           = "../../modules/alb"
  vpc_id           = module.vpc.vpc_id
  public_subnet_ids = module.vpc.public_subnet_ids
  alb_sg_id        = module.sg.alb_sg_id
  prefix           = var.prefix
  env              = var.env
  account_id       = var.account_id
  tags             = local.common_tags
}

module "asg" {
  source                = "../../modules/asg"
  prefix                = var.prefix
  env                   = var.env
  private_subnet_ids    = module.vpc.private_subnet_ids
  ec2_sg_id             = module.sg.ec2_sg_id
  target_group_arn      = module.alb.target_group_arn
  instance_profile_name = module.iam.instance_profile_name  # Phase 3 で定義
  min_size              = var.asg_min_size
  max_size              = var.asg_max_size
  desired_capacity      = var.asg_desired_capacity
  tags                  = local.common_tags

  # IAM モジュールに依存（Phase 3 完了後に有効化）
  depends_on = [module.iam]
}
```

`variables.tf` に追加:
- `asg_min_size` = 2
- `asg_max_size` = 6
- `asg_desired_capacity` = 2

`outputs.tf` に追加:
- `alb_dns_name`
- `target_group_arn`
- `asg_name`

---

## 完了条件

- [ ] `terraform fmt` / `terraform validate` が通ること
- [ ] UserData で stress-ng と ヘルスチェックエンドポイントがセットアップされること
- [ ] IMDSv2 強制（http_tokens = "required"）が設定されていること
- [ ] Target Tracking Policy が CPU 70% で設定されていること
- [ ] ALB アクセスログが S3 に出力される設定であること

---

## 次フェーズへの引き継ぎ情報

Phase 3 開始時に必要な情報:
- `module.asg.asg_name`: FIS ターゲットとして使用
- `module.asg.asg_arn`: FIS リソース ARN
- `module.alb.alb_arn`: FIS 停止条件の監視対象