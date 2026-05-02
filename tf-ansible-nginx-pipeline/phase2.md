# ✅Phase 2: Terraformモジュール設計

## このフェーズで達成すること

VPC + EC2 + SSM Parameter Storeをモジュール化し、
「なぜそう書くか」を説明できる設計を実装する。

## Phase 1からの引き継ぎ

Phase 1の `terraform output` で取得した以下の値を使用:
- tfstate_bucket_name: S3バケット名
- tflock_table_name: DynamoDBテーブル名

---

## Task 2-1: VPCモジュールの生成

`terraform/modules/vpc/` 配下に以下のファイルを生成してください。

### `terraform/modules/vpc/main.tf`

```hcl
# =============================================================================
# VPCモジュール
# 設計思想: ネットワーク設計はImmutableなため Terraform で宣言的に管理する
# AZを動的に取得することで、リージョン変更時もコード修正不要にする
# =============================================================================

locals {
  # AZを動的取得: ap-northeast-1a/b/c をハードコードしない
  # 理由: リージョン間の移植性を確保するため
  az_count = min(length(data.aws_availability_zones.available.names), var.az_count)
  azs      = slice(data.aws_availability_zones.available.names, 0, local.az_count)

  # CIDR計算をlocalsに集約する
  # 理由: ビジネスロジック（サブネット設計）をmain.tfから分離して可読性を上げる
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true  # SSM Session Manager接続に必要
  enable_dns_support   = true  # DNS解決を有効化

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# パブリックサブネット（NAT GatewayとBastionを配置）
resource "aws_subnet" "public" {
  # count ではなく for_each を使う理由:
  # countはインデックスベースのため、中間要素を削除すると後続リソースが再作成される
  # for_eachはキーベースのため、特定AZのサブネットだけ削除しても他に影響しない
  for_each = { for i, az in local.azs : az => local.public_subnets[i] }

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = each.key
  map_public_ip_on_launch = false  # パブリックIPは明示的にEIPで管理する

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    Tier = "public"
  }
}

# プライベートサブネット（EC2本体を配置）
resource "aws_subnet" "private" {
  for_each = { for i, az in local.azs : az => local.private_subnets[i] }

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = each.key

  tags = {
    Name = "${var.name_prefix}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

# NAT Gateway: プライベートサブネットからのアウトバウンド通信用
# ハンズオン用: AZ冗長化コスト削減のため1つだけ配置
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  # values()でマップから最初の1つを取得（ハンズオン用シングルNAT）
  subnet_id     = values(aws_subnet.public)[0].id
  allocation_id = aws_eip.nat.id
  tags          = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.this]
  # depends_on を使っている理由:
  # IGWがアタッチされる前にNAT GatewayをEIPに紐付けるとエラーになるため
  # このケースは暗黙的依存関係では解決できないため明示的に記述
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# VPCエンドポイント（SSM Session Manager用）
# 理由: プライベートサブネットのEC2にSSMアクセスするためインターネット経由を避ける
resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.vpce.id]
  private_dns_enabled = true

  tags = { Name = "${var.name_prefix}-vpce-${each.key}" }
}

resource "aws_security_group" "vpce" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "VPCエンドポイント用: EC2からSSMへのHTTPS通信を許可"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]  # VPC内からのみ許可
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### `terraform/modules/vpc/variables.tf`

```hcl
variable "name_prefix" {
  description = "リソース命名プレフィックス（例: handson-dev）"
  type        = string
}

variable "aws_region" {
  description = "AWSリージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "VPC CIDRブロック"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidrは有効なCIDR形式で指定してください。"
  }
}

variable "az_count" {
  description = "使用するAZ数（最大3）"
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 3
    error_message = "az_countは1から3の間で指定してください。"
  }
}
```

### `terraform/modules/vpc/outputs.tf`

```hcl
output "vpc_id" {
  description = "VPC ID（computeモジュールで使用）"
  value       = aws_vpc.this.id
}

output "private_subnet_ids" {
  description = "プライベートサブネットIDリスト（EC2配置用）"
  value       = [for s in aws_subnet.private : s.id]
}

output "public_subnet_ids" {
  description = "パブリックサブネットIDリスト（ALB配置用）"
  value       = [for s in aws_subnet.public : s.id]
}

output "vpc_cidr" {
  description = "VPC CIDRブロック（セキュリティグループルール設定に使用）"
  value       = aws_vpc.this.cidr_block
}
```

---

## Task 2-2: Computeモジュールの生成

`terraform/modules/compute/` 配下に以下のファイルを生成してください。

### `terraform/modules/compute/main.tf`

```hcl
# =============================================================================
# Computeモジュール
# 設計思想: EC2はTerraformで「存在」を管理し、内部設定はAnsibleに委譲する
# user_dataは最小限（SSMエージェント起動確認のみ）とし、
# ミドルウェア設定はAnsibleで行う
# =============================================================================

# 最新のAmazon Linux 2023 AMIを動的取得
# ハードコードしない理由: AMI IDはリージョン・時間によって変わるため
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# SSMセッションマネージャー用IAMロール
resource "aws_iam_role" "ec2_ssm" {
  name = "${var.name_prefix}-ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

# AmazonSSMManagedInstanceCoreのみアタッチ
# 理由: SSHを使わずSSMでアクセスするための最小権限セット
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ec2_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# SSMパラメータ読み取り用インラインポリシー
# 理由: Ansibleが実行時にSSMパラメータを取得するための権限
resource "aws_iam_role_policy" "ssm_params_read" {
  name = "${var.name_prefix}-ssm-params-read"
  role = aws_iam_role.ec2_ssm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/${var.name_prefix}/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_ssm" {
  name = "${var.name_prefix}-ec2-instance-profile"
  role = aws_iam_role.ec2_ssm.name
}

# EC2用セキュリティグループ
resource "aws_security_group" "ec2" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "EC2インスタンス用: アウトバウンドのみ許可（SSM経由で管理）"
  vpc_id      = var.vpc_id

  # インバウンドルールなし: SSMセッションマネージャーはインバウンドポート不要
  # SSM接続の仕組み: EC2からSSMエンドポイントへのアウトバウンド443で実現

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "全アウトバウンド許可: パッケージ取得・SSM通信用"
  }

  tags = { Name = "${var.name_prefix}-ec2-sg" }
}

resource "aws_instance" "web" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.private_subnet_ids[0]
  iam_instance_profile   = aws_iam_instance_profile.ec2_ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # user_dataは最小限: SSMエージェントの動作確認のみ
  # ミドルウェア（nginx等）のインストールはAnsibleで行う
  user_data = base64encode(<<-EOF
    #!/bin/bash
    # SSMエージェントが起動していることを確認
    systemctl enable amazon-ssm-agent
    systemctl start amazon-ssm-agent
  EOF
  )

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true  # 静止時暗号化: セキュリティ要件
    delete_on_termination = true
  }

  tags = {
    Name    = "${var.name_prefix}-web"
    Role    = "web"           # Ansible Dynamic Inventoryのフィルタリング用タグ
    AnsibleManaged = "true"   # Ansibleで管理対象であることを明示
  }
}
```

### `terraform/modules/compute/variables.tf`

```hcl
variable "name_prefix"       { type = string }
variable "aws_region"        { type = string; default = "ap-northeast-1" }
variable "vpc_id"            { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "instance_type"     { type = string; default = "t3.micro" }
```

### `terraform/modules/compute/outputs.tf`

```hcl
output "instance_id" {
  description = "EC2インスタンスID（Ansible Dynamic Inventoryで自動取得されるが、GitHub Actionsでの確認用）"
  value       = aws_instance.web.id
}

output "private_ip" {
  description = "プライベートIP（Ansible接続先確認用）"
  value       = aws_instance.web.private_ip
}
```

---

## Task 2-3: SSMモジュールの生成

`terraform/modules/ssm/main.tf`:

```hcl
# =============================================================================
# SSMパラメータモジュール
# 設計思想: TerraformがパラメータをSSMに書き込み、Ansibleが読み取る
# これにより設定値がコードとして管理され、Ansibleのvarsファイルへのハードコードを防ぐ
# =============================================================================

resource "aws_ssm_parameter" "nginx_port" {
  name        = "/${var.name_prefix}/nginx/port"
  type        = "String"
  value       = tostring(var.nginx_port)
  description = "nginxリスンポート番号"
}

resource "aws_ssm_parameter" "nginx_worker_processes" {
  name        = "/${var.name_prefix}/nginx/worker_processes"
  type        = "String"
  value       = var.nginx_worker_processes
  description = "nginxワーカープロセス数（autoでCPUコア数に自動調整）"
}
```

`terraform/modules/ssm/variables.tf`:

```hcl
variable "name_prefix"             { type = string }
variable "nginx_port"              { type = number; default = 80 }
variable "nginx_worker_processes"  { type = string; default = "auto" }
```

`terraform/modules/ssm/outputs.tf`:

```hcl
output "nginx_port_param_name" {
  description = "Ansible vars_filesで参照するパラメータ名"
  value       = aws_ssm_parameter.nginx_port.name
}
```

---

## Task 2-4: 環境設定ファイルの生成

`terraform/environments/dev/main.tf`:

```hcl
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }

  backend "s3" {
    # Phase 1のbootstrap outputで取得した値を設定
    bucket         = "handson-dev-tfstate"      # terraform output tfstate_bucket_name
    key            = "handson/dev/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "handson-dev-tflock"       # terraform output tflock_table_name
  }
}

provider "aws" {
  region = "ap-northeast-1"
  default_tags {
    tags = {
      Project     = "handson"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

module "vpc" {
  source      = "../../modules/vpc"
  name_prefix = local.name_prefix
  aws_region  = "ap-northeast-1"
  vpc_cidr    = "10.0.0.0/16"
  az_count    = 2
}

module "compute" {
  source             = "../../modules/compute"
  name_prefix        = local.name_prefix
  aws_region         = "ap-northeast-1"
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  instance_type      = "t3.micro"
}

module "ssm" {
  source      = "../../modules/ssm"
  name_prefix = local.name_prefix
}

locals {
  name_prefix = "handson-dev"
}
```

`terraform/environments/dev/outputs.tf`:

```hcl
output "instance_id" {
  description = "Phase 4のGitHub Actions確認用"
  value       = module.compute.instance_id
}

output "vpc_id" {
  value = module.vpc.vpc_id
}
```

---

## Task 2-5: for_each vs count の解説ドキュメント

`docs/terraform-for_each-vs-count.md` を作成してください:

```markdown
# for_each vs count: 使い分けの判断軸

## count を使っていい場合
- リソースが「同一の設定」で複数作られる場合
- 削除されるのが常に「末尾」であることが保証できる場合
- 例: 同じ設定のNAT Gatewayをn個作りたい

## for_each を使うべき場合
- リソースに「意味のある識別子」がある場合（AZ名、ロール名等）
- 中間要素の削除が発生しうる場合
- 例: AZごとのサブネット、環境ごとのS3バケット

## なぜ中間削除でcountが問題になるのか

count = 3 でサブネットa, b, cを作成後、bを削除したい場合:
- count = 2 にするとTerraformはインデックス2（c）を削除しようとする
- 意図しないリソースが削除される危険がある

for_each = {a: cidr1, c: cidr3} にすれば:
- キーbに対応するリソースだけが削除される
- cは影響を受けない
```

---

## Phase 2 実行コマンド

```bash
cd terraform/environments/dev
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

# 出力確認（Phase 4で使用）
terraform output instance_id
```

## Phase 3への引き継ぎ情報

- instance_id: EC2インスタンスID（SSMセッション接続確認用）
- AnsibleのDynamic Inventoryが `Role=web` タグで自動的にインスタンスを検出する