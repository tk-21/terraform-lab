# ✅Phase 3: Packer テンプレート + GitHub Actions AMI ビルドパイプライン

## 前フェーズの要約

Phase 1: ディレクトリ骨格・ベース設定ファイルを生成
Phase 2: Ansible 3ロール実装（cis-benchmark / docker-runtime / eks-node-prep）

## このフェーズの目的

1. Packer HCL2 テンプレートで Golden AMI をビルドする設定を実装
2. GitHub Actions (OIDC) で AMI ビルドパイプラインを自動化

IAM Access Key は一切使用しない。OIDC のみで認証する。

---

## タスク一覧

### 1. Packer HCL2 テンプレート

**ファイル: `packer/golden-ami.pkr.hcl`**

```hcl
# Golden AMI Packer テンプレート
# Amazon Linux 2023 (arm64) に CIS Benchmark + containerd + EKS準備を適用して AMI を作成する

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
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
  ami_name    = "golden-ami-eks-${var.eks_version}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "EKS ${var.eks_version} Golden AMI - CIS Level1 + containerd"

  # タグ（全リソース共通）
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
  # リージョン設定
  region = var.aws_region

  # ベース AMI（Data Sourceから動的取得）
  source_ami   = data.amazon-ami.amazon_linux_2023.id
  instance_type = var.instance_type

  # AMI設定
  ami_name        = local.ami_name
  ami_description = local.ami_description

  # ストレージ設定
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30   # GB - EKSノード推奨サイズ
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true  # AMI暗号化（セキュリティ要件）
  }

  # ネットワーク設定（サブネット指定がある場合のみ）
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

  # SSH 接続設定（ビルド中のAnsible接続用）
  communicator = "ssh"
  ssh_username = "ec2-user"

  # IMDSv2 を強制（セキュリティベストプラクティス）
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # AMI タグ
  tags        = local.tags
  snapshot_tags = local.tags

  # ビルドインスタンスにも同じタグを付与
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

    # Ansible extra_vars で EKS バージョンを渡す
    extra_arguments = [
      "--extra-vars", "eks_version=${var.eks_version}",
      "--extra-vars", "aws_region=${var.aws_region}",
      # 詳細ログ出力（ビルド失敗時のデバッグ用）
      "-v"
    ]

    # ansible.cfg を指定
    ansible_env_vars = [
      "ANSIBLE_CONFIG=../ansible/ansible.cfg",
      "ANSIBLE_ROLES_PATH=../ansible/roles"
    ]
  }

  # Step 2: シェルスクリプトでクリーンアップ
  provisioner "shell" {
    inline = [
      # パッケージキャッシュ削除
      "sudo dnf clean all",
      # ログ削除（AMIにビルドログを含めない）
      "sudo rm -rf /var/log/audit/audit.log",
      "sudo truncate -s 0 /var/log/messages",
      "sudo truncate -s 0 /var/log/secure",
      # SSH host keys 削除（各インスタンスで再生成させる）
      "sudo rm -f /etc/ssh/ssh_host_*",
      # cloud-init のリセット（次回起動時に再初期化）
      "sudo cloud-init clean --logs",
      # AMI ビルド完了ログ
      "echo 'Golden AMI build cleanup completed'"
    ]
  }

  # Step 3: AMI の詳細情報をマニフェストファイルに出力
  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
```

---

### 2. GitHub Actions: AMI ビルドワークフロー

**ファイル: `.github/workflows/ami-build.yml`**

```yaml
name: Golden AMI Build

on:
  # 手動トリガー（バージョン指定可能）
  workflow_dispatch:
    inputs:
      eks_version:
        description: "EKS Version (e.g. 1.30)"
        required: true
        default: "1.30"
      dry_run:
        description: "Dry run (validate only, no AMI build)"
        required: false
        default: "false"
        type: boolean

  # AMI関連ファイルの変更時に自動実行
  push:
    branches:
      - main
    paths:
      - "ansible/**"
      - "packer/**"

permissions:
  # OIDC認証に必要
  id-token: write
  contents: read

env:
  AWS_REGION: ap-northeast-1
  PACKER_VERSION: "1.10.3"
  ANSIBLE_VERSION: "2.15.*"

jobs:
  validate:
    name: Validate Packer Template
    runs-on: ubuntu-latest

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup Packer
        uses: hashicorp/setup-packer@main
        with:
          version: ${{ env.PACKER_VERSION }}

      - name: Packer Init
        run: packer init packer/golden-ami.pkr.hcl

      - name: Packer Validate
        run: |
          packer validate \
            -var "aws_region=${{ env.AWS_REGION }}" \
            -var "eks_version=${{ inputs.eks_version || '1.30' }}" \
            packer/golden-ami.pkr.hcl

      - name: Ansible Syntax Check
        run: |
          pip install ansible==${{ env.ANSIBLE_VERSION }} ansible-lint
          ansible-playbook \
            --syntax-check \
            -i ansible/inventory/packer_hosts \
            ansible/playbooks/golden-ami.yml

  build:
    name: Build Golden AMI
    runs-on: ubuntu-latest
    needs: validate
    # dry_run が false の場合のみ実行
    if: ${{ inputs.dry_run != 'true' || github.event_name == 'push' }}

    environment: production  # GitHub Environments で承認フローを設定可能

    outputs:
      ami_id: ${{ steps.get_ami_id.outputs.ami_id }}

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: AWS OIDC 認証
        # IAM Access Key を使わない。OIDC で一時クレデンシャルを取得する
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/eks-golden-node-pipeline-github-actions-role
          aws-region: ${{ env.AWS_REGION }}
          role-session-name: GitHubActions-AMIBuild-${{ github.run_id }}

      - name: Setup Packer
        uses: hashicorp/setup-packer@main
        with:
          version: ${{ env.PACKER_VERSION }}

      - name: Install Ansible
        run: pip install ansible==${{ env.ANSIBLE_VERSION }}

      - name: Packer Init
        run: packer init packer/golden-ami.pkr.hcl

      - name: Build Golden AMI
        run: |
          packer build \
            -var "aws_region=${{ env.AWS_REGION }}" \
            -var "eks_version=${{ inputs.eks_version || '1.30' }}" \
            packer/golden-ami.pkr.hcl
        env:
          # Packer のタイムアウト設定
          PACKER_LOG: 1

      - name: AMI ID を取得
        id: get_ami_id
        run: |
          AMI_ID=$(jq -r '.builds[-1].artifact_id' packer-manifest.json | cut -d: -f2)
          echo "ami_id=${AMI_ID}" >> $GITHUB_OUTPUT
          echo "Built AMI ID: ${AMI_ID}"

      - name: AMI ビルド結果をサマリーに出力
        run: |
          echo "## Golden AMI Build Result" >> $GITHUB_STEP_SUMMARY
          echo "| Key | Value |" >> $GITHUB_STEP_SUMMARY
          echo "|---|---|" >> $GITHUB_STEP_SUMMARY
          echo "| AMI ID | ${{ steps.get_ami_id.outputs.ami_id }} |" >> $GITHUB_STEP_SUMMARY
          echo "| EKS Version | ${{ inputs.eks_version || '1.30' }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Region | ${{ env.AWS_REGION }} |" >> $GITHUB_STEP_SUMMARY
          echo "| Build Run | ${{ github.run_id }} |" >> $GITHUB_STEP_SUMMARY

  notify-failure:
    name: Failure Notification
    runs-on: ubuntu-latest
    needs: [validate, build]
    if: failure()

    steps:
      - name: Chatwork 通知（ビルド失敗）
        # 他プロジェクトと統一: Chatwork API で通知
        run: |
          curl -X POST \
            -H "X-ChatWorkToken: ${{ secrets.CHATWORK_API_TOKEN }}" \
            -d "body=[info][title]❌ Golden AMI Build Failed[/title]Workflow: ${{ github.workflow }}%0ARun: ${{ github.run_id }}%0ABranch: ${{ github.ref_name }}[/info]" \
            "https://api.chatwork.com/v2/rooms/${{ secrets.CHATWORK_ROOM_ID }}/messages"
```

---

### 3. GitHub Actions: Terraform ワークフロー（スケルトン）

**ファイル: `.github/workflows/terraform.yml`**

```yaml
name: Terraform Plan / Apply

on:
  pull_request:
    branches: [main]
    paths:
      - "terraform/**"
  push:
    branches: [main]
    paths:
      - "terraform/**"

permissions:
  id-token: write
  contents: read
  pull-requests: write  # PRにplanコメントを投稿するため

env:
  AWS_REGION: ap-northeast-1
  TF_VERSION: "1.7.5"
  WORKING_DIR: terraform/environments/dev

jobs:
  terraform:
    name: Terraform ${{ github.event_name == 'push' && 'Apply' || 'Plan' }}
    runs-on: ubuntu-latest

    defaults:
      run:
        working-directory: ${{ env.WORKING_DIR }}

    steps:
      - uses: actions/checkout@v4

      - name: AWS OIDC 認証
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/eks-golden-node-pipeline-github-actions-role
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        run: terraform init

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -out=tfplan -no-color

      - name: PR に Plan 結果をコメント
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const output = `### Terraform Plan
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

      - name: Terraform Apply（main ブランチのみ）
        if: github.event_name == 'push' && github.ref == 'refs/heads/main'
        run: terraform apply tfplan
```

---

## 完了条件

- [ ] `packer/golden-ami.pkr.hcl` が存在する
- [ ] `.github/workflows/ami-build.yml` が存在する
- [ ] `.github/workflows/terraform.yml` が存在する
- [ ] `packer validate` が構文エラーなく通過する（ローカル確認不要、ファイル生成のみ）

## 次フェーズへの引き継ぎ

Phase 4 では Terraform モジュール（VPC / EKS）を実装する。
Golden AMI の AMI ID は Phase 5 で Karpenter EC2NodeClass に組み込む。