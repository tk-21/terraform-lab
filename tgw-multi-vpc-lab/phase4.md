# Phase 4: テスト用EC2 + 疎通確認

## このフェーズの目的
実際にEC2インスタンスを各VPCに配置し、通信ポリシーが正しく機能していることを確認する。
「設定した」ではなく「動作を確認した」レベルで理解を完了させる。

## 前提条件
- Phase 3完了済み（TGWルートテーブルの関連付け・伝播が設定済み）
- SSM Session Managerでアクセスできること（NATGWなし構成のため）

---

## タスク一覧

### 1. テスト用EC2モジュールの作成

```
modules/
└── test-ec2/
    ├── main.tf
    ├── variables.tf
    └── outputs.tf
```

**main.tf**:

```hcl
# ─────────────────────────────────────────
# 疎通確認専用のEC2インスタンス
# SSMアクセスのため、IAMロールとVPCエンドポイントが必要
# コスト最小化: t4g.nano + Spot
# ─────────────────────────────────────────

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-arm64"]
  }
}

resource "aws_iam_role" "ssm" {
  name = "${var.instance_name}-ssm-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.instance_name}-ssm-profile"
  role = aws_iam_role.ssm.name
}

resource "aws_security_group" "ec2" {
  name        = "${var.instance_name}-sg"
  description = "Test EC2 SG - allow ICMP from private ranges"
  vpc_id      = var.vpc_id

  # ICMPを内部レンジから許可（疎通確認用）
  ingress {
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.amazon_linux_2023.id
  instance_type          = "t4g.nano"  # arm64 / Graviton2
  subnet_id              = var.subnet_id
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids = [aws_security_group.ec2.id]

  # Spot: コスト削減のため
  instance_market_options {
    market_type = "spot"
  }

  tags = merge(var.tags, { Name = var.instance_name })
}
```

**variables.tf**:
```hcl
variable "instance_name"
variable "vpc_id"
variable "subnet_id"   # プライベートサブネットの1つ
variable "tags"
```

**outputs.tf**:
```hcl
output "instance_id"
output "private_ip"
```

### 2. 各VPCにテスト用EC2を配置

`envs/ap-northeast-1/main.tf` に追記:

```hcl
module "test_ec2_hub" {
  source        = "../../modules/test-ec2"
  instance_name = "test-hub"
  vpc_id        = module.hub_vpc.vpc_id
  subnet_id     = values(module.hub_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}

module "test_ec2_spoke_a" {
  source        = "../../modules/test-ec2"
  instance_name = "test-spoke-a"
  vpc_id        = module.spoke_a_vpc.vpc_id
  subnet_id     = values(module.spoke_a_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}

module "test_ec2_spoke_b" {
  source        = "../../modules/test-ec2"
  instance_name = "test-spoke-b"
  vpc_id        = module.spoke_b_vpc.vpc_id
  subnet_id     = values(module.spoke_b_vpc.private_subnet_ids)[0]
  tags          = local.common_tags
}
```

### 3. 疎通確認スクリプトの作成

`tests/connectivity_check.sh`:

```bash
#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────
# TGWルーティング疎通確認スクリプト
# 期待値:
#   Spoke-A → Hub:     PASS（許可）
#   Spoke-B → Hub:     PASS（許可）
#   Spoke-A → Spoke-B: FAIL（禁止）
# ─────────────────────────────────────────

cd "$(dirname "$0")/../envs/ap-northeast-1"

HUB_IP=$(terraform output -raw test_hub_private_ip)
SPOKE_A_ID=$(terraform output -raw test_spoke_a_instance_id)
SPOKE_B_IP=$(terraform output -raw test_spoke_b_private_ip)

echo "=== 疎通確認開始 ==="
echo "Hub IP:     $HUB_IP"
echo "Spoke-B IP: $SPOKE_B_IP"
echo ""

run_ping() {
  local source_instance=$1
  local target_ip=$2
  local label=$3
  local expect_success=$4

  echo -n "[$label] Ping $target_ip from $source_instance ... "
  
  result=$(aws ssm send-command \
    --instance-id "$source_instance" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"ping -c 3 -W 2 $target_ip > /dev/null 2>&1 && echo SUCCESS || echo FAIL\"]" \
    --query 'Command.CommandId' \
    --output text)
  
  sleep 5
  
  output=$(aws ssm get-command-invocation \
    --command-id "$result" \
    --instance-id "$source_instance" \
    --query 'StandardOutputContent' \
    --output text | tr -d '\n')
  
  if [[ "$output" == "SUCCESS" && "$expect_success" == "true" ]]; then
    echo "✅ PASS（通信OK、期待通り）"
  elif [[ "$output" == "FAIL" && "$expect_success" == "false" ]]; then
    echo "✅ PASS（通信NG、期待通り遮断）"
  elif [[ "$output" == "SUCCESS" && "$expect_success" == "false" ]]; then
    echo "❌ FAIL（通信OK、遮断されるべき）"
  else
    echo "❌ FAIL（通信NG、通信できるべき）"
  fi
}

# Spoke-A → Hub（許可されるべき）
run_ping "$SPOKE_A_ID" "$HUB_IP" "Spoke-A → Hub" "true"

# Spoke-A → Spoke-B（遮断されるべき）
run_ping "$SPOKE_A_ID" "$SPOKE_B_IP" "Spoke-A → Spoke-B" "false"

echo ""
echo "=== 確認完了 ==="
```

```bash
chmod +x tests/connectivity_check.sh
```

### 4. `terraform apply` + テスト実行

```bash
terraform -chdir=envs/ap-northeast-1 plan
terraform -chdir=envs/ap-northeast-1 apply

# SSMエージェント起動を待つ（2〜3分）
sleep 120

bash tests/connectivity_check.sh
```

---

## 完了確認

### 期待される出力

```
=== 疎通確認開始 ===
Hub IP:     10.0.1.xxx
Spoke-B IP: 10.2.1.xxx

[Spoke-A → Hub]     Ping 10.0.1.xxx ... ✅ PASS（通信OK、期待通り）
[Spoke-A → Spoke-B] Ping 10.2.1.xxx ... ✅ PASS（通信NG、期待通り遮断）

=== 確認完了 ===
```

### 手動確認コマンド

```bash
# SSM Session Managerでログイン
SPOKE_A_ID=$(terraform -chdir=envs/ap-northeast-1 output -raw test_spoke_a_instance_id)
aws ssm start-session --target $SPOKE_A_ID

# セッション内で
ping 10.0.1.x   # Hub → 通るはず
ping 10.2.1.x   # Spoke-B → タイムアウトするはず
traceroute 10.0.1.x  # 経路確認
```

---

## 口頭説明チェック（15分目安）

1. **Spoke-AからHub行きのパケットが通る経路を全て説明せよ**
   （EC2 → VPCルートテーブル → TGW ENI → Spoke RT → Hub RT経由 → ...）

2. **Spoke-AからSpoke-B行きのパケットがどこで止まるか説明せよ**
   TGWのどのルートテーブルで、なぜドロップされるか？

3. **SSM Session Managerでアクセスできる仕組みを説明せよ**
   NATGWもパブリックIPもない状態でなぜ接続できるか？

4. **このテスト構成の費用は月額いくらか概算できるか？**
   t4g.nano Spot × 3インスタンスの料金を概算してみること。

---

## 次のフェーズ
Phase 5: ドキュメント整備（ADR・Mermaid図・Zenn記事アウトライン）