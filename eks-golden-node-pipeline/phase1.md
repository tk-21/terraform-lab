# ✅Phase 1: ディレクトリ骨格 + ベースファイル生成

## このフェーズの目的

プロジェクト `eks-golden-node-pipeline` のディレクトリ構造を作成し、
各ツール（Ansible / Packer / Terraform）のベース設定ファイルを生成する。

CLAUDE.md に定義された構造・命名規則・タグ戦略を厳守すること。

---

## タスク一覧

### 1. ディレクトリ構造の作成

以下のディレクトリをすべて作成する（CLAUDE.md の「ディレクトリ構造」セクション参照）：

```
eks-golden-node-pipeline/
├── .github/workflows/
├── ansible/playbooks/
├── ansible/roles/cis-benchmark/{tasks,handlers,defaults}/
├── ansible/roles/docker-runtime/tasks/
├── ansible/roles/eks-node-prep/tasks/
├── ansible/inventory/
├── packer/
├── terraform/environments/dev/
├── terraform/modules/vpc/
├── terraform/modules/eks/
├── terraform/modules/karpenter/templates/
└── docs/adr/
```

### 2. Ansible ベース設定

**ファイル: `ansible/ansible.cfg`**

```ini
[defaults]
# インベントリのデフォルトパス
inventory = inventory/packer_hosts
# ロールの検索パス
roles_path = roles
# SSH接続のタイムアウト設定
timeout = 30
# ホストキー検証を無効化（Packer一時インスタンス用）
host_key_checking = False
# 出力をカラー表示
force_color = True
# 冪等性確認のためログを有効化
log_path = /tmp/ansible.log

[ssh_connection]
# SSH多重化で高速化
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
```

**ファイル: `ansible/inventory/packer_hosts`**

```ini
# Packer が動的に生成するホスト
# Packer の ansible provisioner が自動的にこのインベントリを上書きする
[packer]
# placeholder - Packer実行時に自動設定される
```

**ファイル: `ansible/playbooks/golden-ami.yml`**

```yaml
---
# Golden AMI ビルド用メインPlaybook
# Packer から呼び出される。CIS Benchmark ハードニング → containerd → EKS準備の順に実行
- name: Golden AMI Build Playbook
  hosts: all
  become: true
  gather_facts: true

  vars:
    # EKS バージョン（Packer変数から渡される）
    eks_version: "1.30"
    # AWSリージョン
    aws_region: "ap-northeast-1"

  roles:
    # CIS Benchmark Level1 ハードニング（セキュリティ強化）
    - role: cis-benchmark
      tags: ["security", "cis"]

    # containerd インストール（Dockerランタイム代替）
    - role: docker-runtime
      tags: ["runtime", "containerd"]

    # EKS ノード起動準備（kubelet設定など）
    - role: eks-node-prep
      tags: ["eks", "kubelet"]

  post_tasks:
    - name: AMIビルド完了ログ出力
      ansible.builtin.debug:
        msg: "Golden AMI build completed. EKS={{ eks_version }}, Region={{ aws_region }}"
```

### 3. Packer ベース設定

**ファイル: `packer/variables.pkrvars.hcl`**

```hcl
# Packer 変数定義ファイル
# GitHub Actions から --var-file で渡される

# AWSリージョン
aws_region = "ap-northeast-1"

# ベースAMI（Amazon Linux 2023 最新版）
# AMI IDは定期的に更新されるため、Data Sourceで動的取得する
base_ami_owner = "137112412989"  # Amazon公式アカウント
base_ami_name  = "al2023-ami-2023.*-kernel-*-arm64"  # arm64版

# インスタンスタイプ（ビルド用）
instance_type = "t4g.medium"  # arm64 Graviton

# EKSバージョン
eks_version = "1.30"

# AMI共有設定（必要な場合はAWSアカウントIDを追加）
ami_regions = ["ap-northeast-1"]
```

### 4. Terraform ベース設定

**ファイル: `terraform/environments/dev/terraform.tfvars`**

```hcl
# dev環境の変数値
project     = "eks-golden-node-pipeline"
environment = "dev"
aws_region  = "ap-northeast-1"

# EKS設定
eks_version  = "1.30"
cluster_name = "eks-golden-node-pipeline-dev"

# VPC CIDR
vpc_cidr = "10.0.0.0/16"

# Karpenter設定
karpenter_version = "0.37.0"
```

**ファイル: `terraform/environments/dev/versions.tf`**

```hcl
terraform {
  required_version = ">= 1.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
  }

  # Terraformリモートバックエンド（S3 + DynamoDB）
  # バケット名はデプロイ先AWSアカウントに合わせて変更する
  backend "s3" {
    bucket         = "eks-golden-node-pipeline-tfstate"
    key            = "dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "eks-golden-node-pipeline-tflock"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "eks-golden-node-pipeline"
      Environment = "dev"
      ManagedBy   = "terraform"
      Owner       = "infrastructure-team"
      CostCenter  = "platform"
    }
  }
}
```

### 5. .gitignore

**ファイル: `.gitignore`**

```
# Terraform
**/.terraform/
*.tfstate
*.tfstate.backup
*.tfplan
.terraform.lock.hcl
override.tf
override.tf.json

# Packer
packer_cache/
*.box

# Ansible
*.retry
/tmp/ansible.log

# 機密情報（絶対にコミットしない）
*.pem
*.key
.env
secrets/

# OS
.DS_Store
Thumbs.db
```

### 6. 動作確認コマンドの出力

以下のコマンドを実行してディレクトリ構造を確認し、出力結果を表示する：

```bash
find eks-golden-node-pipeline -type f | sort
```

---

## 完了条件

- [ ] 全ディレクトリが作成されている
- [ ] `ansible/ansible.cfg` が存在する
- [ ] `ansible/playbooks/golden-ami.yml` が存在する
- [ ] `packer/variables.pkrvars.hcl` が存在する
- [ ] `terraform/environments/dev/terraform.tfvars` が存在する
- [ ] `terraform/environments/dev/versions.tf` が存在する
- [ ] `.gitignore` が存在する
- [ ] `find` コマンドの出力にエラーがない

## 次フェーズへの引き継ぎ

Phase 2 では Ansible の各ロール（cis-benchmark / docker-runtime / eks-node-prep）の
tasks を実装する。