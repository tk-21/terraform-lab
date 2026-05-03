# ✅Phase 1: プロジェクト初期化 + Terraform インフラ構築

## このフェーズで行うこと

1. プロジェクトディレクトリ構造を作成する
2. Terraform ファイルを全て生成する
3. Terraform の構文検証を行う（`terraform validate`）

フェーズ完了後に出力すること:
- 生成したファイルの一覧
- `terraform validate` の結果
- Phase 2 実行前に人間がやること（S3バケット名変更など）

---

## 前提確認

以下のツールが使えることを確認してから作業を開始すること。
使えない場合は理由を報告して停止する。

```bash
terraform version
aws --version
```

---

## Step 1: ディレクトリ構造を作成

```bash
mkdir -p aws-lsyncd-sync-infra/{terraform,ansible/{inventory,group_vars,roles/{common,nginx,ssh_key_dist,lsyncd}/{tasks,handlers,templates},playbooks,keys},docs/{adr,runbook},.github/workflows}
cd aws-lsyncd-sync-infra
touch ansible/keys/.gitkeep
```

---

## Step 2: .gitignore を作成

`aws-lsyncd-sync-infra/.gitignore` に以下を書き込む:

```
# Terraform
.terraform/
.terraform.lock.hcl
*.tfplan
*.tfstate
*.tfstate.backup
terraform.tfvars
override.tf

# Ansible
ansible/keys/
*.retry
__pycache__/
*.pyc

# macOS
.DS_Store

# エディタ
*.swp
*.swo
.vscode/
.idea/
```

---

## Step 3: Terraform ファイルを生成

### terraform/backend.tf

```hcl
# =============================================================
# backend.tf — Terraform リモートバックエンド + プロバイダ設定
# S3 で tfstate を管理し、DynamoDB でロックを取得する。
# =============================================================

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
  }

  # ★ 初回 apply 前に S3/DynamoDB を手動作成後、bucket 名を変更すること
  backend "s3" {
    bucket         = "YOUR_TFSTATE_BUCKET_NAME"
    key            = "aws-lsyncd-sync-infra/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "terraform-lock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "aws-lsyncd-sync-infra"
      ManagedBy   = "Terraform"
      Environment = var.environment
    }
  }
}
```

### terraform/variables.tf

```hcl
# =============================================================
# variables.tf — 変数定義
# =============================================================

variable "aws_region" {
  description = "デプロイ先 AWS リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "environment" {
  description = "環境識別子"
  type        = string
  default     = "handson"
}

variable "project_name" {
  description = "リソース名プレフィックス（IAM ロール名 64 文字制限に注意）"
  type        = string
  default     = "lsyncd-ws"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

variable "instance_type" {
  description = "EC2 インスタンスタイプ（コスト最小化）"
  type        = string
  default     = "t3.micro"
}

variable "ami_id" {
  description = "Amazon Linux 2023 AMI (ap-northeast-1)"
  type        = string
  # 最新確認: aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64
  default = "ami-0599b6e53ca798bb2"
}

variable "slave_count" {
  description = "slave EC2 台数"
  type        = number
  default     = 2
}

variable "allowed_ssh_cidr" {
  description = "SSH を許可する CIDR（★ 自宅 IP/32 に変更すること）"
  type        = string
  default     = "0.0.0.0/0"
}
```

### terraform/vpc.tf

```hcl
# =============================================================
# vpc.tf — ネットワーク基盤
# ハンズオン用シンプル構成: 単一 AZ, パブリックサブネットのみ。
# master/slave 間の lsyncd 通信は VPC 内プライベート IP で完結。
# =============================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true # dynamic inventory が DNS 名解決に使用
  enable_dns_support   = true

  tags = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_name}-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_name}-public-subnet" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${var.project_name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}
```

### terraform/security_group.tf

```hcl
# =============================================================
# security_group.tf — EC2 セキュリティグループ
# master/slave 共用。
# lsyncd の rsync over SSH は VPC 内プライベート IP で通信するため
# VPC CIDR からの SSH も許可する。
# =============================================================

resource "aws_security_group" "ec2" {
  name        = "${var.project_name}-ec2-sg"
  description = "lsyncd web sync - master and slave shared SG"
  vpc_id      = aws_vpc.main.id

  # 運用者からの SSH
  ingress {
    description = "SSH from operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # VPC 内 master→slave の lsyncd rsync 用 SSH
  ingress {
    description = "SSH from VPC for lsyncd rsync"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # nginx 動作確認用 HTTP
  ingress {
    description = "HTTP for nginx verification"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-ec2-sg" }
}
```

### terraform/key_pair.tf

```hcl
# =============================================================
# key_pair.tf — EC2 SSH キーペア
# Terraform で RSA 鍵を生成し AWS KeyPair に登録。
# 秘密鍵を ansible/keys/ec2_key.pem に保存（.gitignore 対象）。
#
# ※ この鍵は「運用者→EC2 SSH ログイン」用。
#    「master→slave lsyncd rsync」用鍵は Ansible ssh_key_dist role で別途生成。
# =============================================================

resource "tls_private_key" "ec2" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "ec2" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ec2.public_key_openssh
  tags       = { Name = "${var.project_name}-key" }
}

# 秘密鍵をローカルに保存（パーミッション 0600 必須）
resource "local_sensitive_file" "private_key" {
  content         = tls_private_key.ec2.private_key_pem
  filename        = "${path.module}/../ansible/keys/ec2_key.pem"
  file_permission = "0600"
}
```

### terraform/ec2.tf

```hcl
# =============================================================
# ec2.tf — EC2 インスタンス (master × 1, slave × 2)
# Tag: Role を動的 inventory のグループ分類に使用する。
# =============================================================

resource "aws_instance" "master" {
  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.ec2.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname master
  EOF

  tags = {
    Name = "${var.project_name}-master"
    Role = "master" # Ansible dynamic inventory グループ名
  }
}

resource "aws_instance" "slave" {
  count = var.slave_count

  ami                    = var.ami_id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = aws_key_pair.ec2.key_name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    hostnamectl set-hostname slave-${count.index + 1}
  EOF

  tags = {
    Name = "${var.project_name}-slave-${count.index + 1}"
    Role = "slave"
  }
}
```

### terraform/outputs.tf

```hcl
# =============================================================
# outputs.tf — 動作確認に必要な情報を出力
# =============================================================

output "master_public_ip" {
  value = aws_instance.master.public_ip
}

output "slave_public_ips" {
  value = aws_instance.slave[*].public_ip
}

output "slave_private_ips" {
  description = "lsyncd 設定の転送先（プライベート IP）"
  value       = aws_instance.slave[*].private_ip
}

output "ssh_command_master" {
  value = "ssh -i ansible/keys/ec2_key.pem ec2-user@${aws_instance.master.public_ip}"
}

output "verify_commands" {
  description = "動作確認コマンド"
  value = {
    create_on_master = "ssh -i ansible/keys/ec2_key.pem ec2-user@${aws_instance.master.public_ip} 'echo hello-lsyncd | sudo tee /var/www/html/test.html'"
    check_slave_1    = "curl http://${aws_instance.slave[0].public_ip}/test.html"
    check_slave_2    = "curl http://${aws_instance.slave[1].public_ip}/test.html"
  }
}
```

---

## Step 4: terraform validate を実行

```bash
cd aws-lsyncd-sync-infra/terraform
terraform init -backend=false   # バックエンド初期化をスキップして構文チェックのみ
terraform validate
terraform fmt -recursive
```

---

## Phase 1 完了条件

- [ ] `terraform validate` が `Success! The configuration is valid.` を返す
- [ ] `terraform fmt` でフォーマット済み
- [ ] 全 tf ファイルが存在する

## Phase 1 完了後に人間がやること（Claude Code では実行しない）

1. `backend.tf` の `YOUR_TFSTATE_BUCKET_NAME` を実際のバケット名に変更
2. S3 バケットと DynamoDB テーブルを手動作成（Runbook 参照）
3. `variables.tf` の `allowed_ssh_cidr` を自宅 IP/32 に変更
4. 最新 AMI ID を確認して `ami_id` を更新する場合は変更
5. `terraform init`（バックエンド込み）を実行
6. `terraform apply` を実行

## 次フェーズへの引き継ぎ情報

Phase 2 (Ansible) に渡す情報:
- プロジェクトルート: `aws-lsyncd-sync-infra/`
- EC2 秘密鍵: `ansible/keys/ec2_key.pem`（terraform apply 後に生成）
- EC2 Tag: Role=master / Role=slave（dynamic inventory で使用）