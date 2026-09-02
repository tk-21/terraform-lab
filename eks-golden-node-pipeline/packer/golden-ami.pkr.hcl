# Golden AMI Packer テンプレート
# Amazon Linux 2023 (arm64) に CIS Benchmark + containerd + EKS準備を適用して AMI を作成する

packer {
  required_plugins {
    amazon = {
      version = "~> 1.8.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = "~> 1.1.6"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# === 変数定義 ===

variable "aws_region" {
  description = "AMIをビルドするAWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "instance_type" {
  description = "ビルド用EC2インスタンスタイプ（arm64）"
  type        = string
  default     = "t4g.medium"
}

variable "eks_version" {
  description = "対象EKSバージョン"
  type        = string
  default     = "1.30"
}

variable "base_ami_owner" {
  description = "ベースAMIのオーナーAWSアカウントID（Amazonは137112412989）"
  type        = string
  default     = "137112412989"
}

variable "subnet_id" {
  description = "ビルド用サブネットID（GitHub Actionsのシークレットから渡す）"
  type        = string
  default     = ""
}

variable "vpc_id" {
  description = "ビルド用VPC ID"
  type        = string
  default     = ""
}

# === ローカル変数 ===

locals {
  # AMI名にタイムスタンプを含める（Immutable AMI原則）
  ami_name        = "golden-ami-eks-${var.eks_version}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "EKS ${var.eks_version} Golden AMI - CIS Level1 + containerd"

  tags = {
    Project      = "eks-golden-node-pipeline"
    ManagedBy    = "packer"
    EKSVersion   = var.eks_version
    CISLevel     = "1"
    Architecture = "arm64"
  }
}

# === データソース: 最新の Amazon Linux 2023 AMI を動的取得 ===

data "amazon-ami" "amazon_linux_2023" {
  filters = {
    # Amazon Linux 2023 arm64 カーネル最新版
    name                = "al2023-ami-2023.*-kernel-*-arm64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    architecture        = "arm64"
  }
  most_recent = true
  owners      = [var.base_ami_owner]
  region      = var.aws_region
}

# === ソース: EC2 ビルドインスタンス設定 ===

source "amazon-ebs" "golden_ami" {
  region = var.aws_region

  source_ami    = data.amazon-ami.amazon_linux_2023.id
  instance_type = var.instance_type

  ami_name        = local.ami_name
  ami_description = local.ami_description

  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # サブネット未指定時はタグで自動選択
  dynamic "subnet_filter" {
    for_each = var.subnet_id == "" ? [1] : []
    content {
      filters = {
        "tag:Name" = "*private*"
      }
      most_free = true
    }
  }
  subnet_id = var.subnet_id != "" ? var.subnet_id : null

  # GitHub-hosted Runner が SSH で一時ビルドインスタンスへ到達するために必要
  # public subnet を subnet_id で明示指定して使用する
  associate_public_ip_address = true

  communicator = "ssh"
  # Packer が private IP ではなく一時インスタンスの public IP に SSH 接続する
  ssh_interface = "public_ip"
  ssh_username  = "ec2-user"

  # IMDSv2 強制（セキュリティベストプラクティス）
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tags          = local.tags
  snapshot_tags = local.tags

  run_tags = merge(local.tags, {
    Name = "packer-golden-ami-build"
  })
}

# === ビルドステップ ===

build {
  name    = "golden-ami-build"
  sources = ["source.amazon-ebs.golden_ami"]

  # Step 1: Ansible プロビジョニング
  provisioner "ansible" {
    playbook_file = "../ansible/playbooks/golden-ami.yml"
    # AL2023 の SFTP サーバーの実パスを指定する
    sftp_command = "/usr/libexec/openssh/sftp-server -e"
    # Packer が生成する inventory が SFTP を強制するため、SFTP proxy を無効化する
    # Ansible 側では ansible.cfg の ssh_transfer_method = piped を使用する
    use_sftp = false
    # provisioner のデフォルトは Packer 実行ユーザーのため、EC2 ユーザーを明示する
    user = "ec2-user"

    extra_arguments = [
      "--extra-vars", "eks_version=${var.eks_version}",
      "--extra-vars", "aws_region=${var.aws_region}",
      "-v"
    ]

    ansible_env_vars = [
      "ANSIBLE_CONFIG=../ansible/ansible.cfg",
      "ANSIBLE_ROLES_PATH=../ansible/roles"
    ]
  }

  # Step 2: クリーンアップ（AMIにビルド成果物を残さない）
  provisioner "shell" {
    inline = [
      "sudo dnf clean all",
      "sudo rm -rf /var/log/audit/audit.log",
      "sudo truncate -s 0 /var/log/messages",
      "sudo truncate -s 0 /var/log/secure",
      "sudo rm -f /etc/ssh/ssh_host_*",
      "sudo cloud-init clean --logs",
      "echo 'Golden AMI build cleanup completed'"
    ]
  }

  # Step 3: AMI 詳細情報をマニフェストに出力
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
