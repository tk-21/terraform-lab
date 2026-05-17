# ✅Phase 2: AWS Network Firewall 構築

## このフェーズの目標

- AWS Network Firewall を Firewall サブネットに配置し、
  **東西（VPC 内部間）トラフィックと南北（Internet 向け）トラフィックを制御する**
- ステートフルルール / ステートレスルールの役割分担を Terraform コードで表現する
- ドメインベースのフィルタリング（許可リスト方式）を実装する
- ルートテーブルの **Traffic Chaining** パターンを理解・実装する

---

## Phase 1 完了の前提

- `amf-vpc`、Firewall サブネット（`10.0.100.0/28`, `10.0.101.0/28`）が存在すること
- `terraform/modules/vpc/` の outputs から以下が取得できること:
  - `firewall_subnet_ids`
  - `public_subnet_ids`
  - `vpc_id`
  - `internet_gateway_id`

---

## 生成対象ファイル

### terraform/modules/network_firewall/

**設計方針（main.tf の冒頭コメントとして必ず記載）**:
```
# AWS Network Firewall はステートフルな L3-L7 ファイアウォール。
# SG・NACL が EC2/サブネットレベルの制御であるのに対し、
# Network Firewall は VPC レベルの集中制御ポイントとして機能する。
#
# 配置場所: Firewall 専用サブネット（/28 で十分）
# トラフィックフロー（Ingress）:
#   Internet → IGW → [Firewall Endpoint] → Public Subnet → EC2
# トラフィックフロー（Egress）:
#   EC2 → [Firewall Endpoint] → IGW → Internet
#
# ルートテーブルを操作して Firewall Endpoint 経由を強制することが核心。
# Firewall Endpoint の ID は Terraform の output から動的に取得する。
```

**main.tf** — 以下のリソースを作成:

#### 1. ステートレスルールグループ: `amf-nfw-stateless-rg`

```hcl
# ステートレスルール: パケット単位の高速フィルタリング（L3/L4）
# 主目的: 明らかな悪意のある送信元 IP をドロップ、その他は転送
resource "aws_networkfirewall_rule_group" "stateless" {
  name     = "${var.prefix}-nfw-stateless-rg"
  type     = "STATELESS"
  capacity = 100

  rule_group {
    rules_source {
      stateless_rules_and_custom_actions {
        # ルール1: プライベートIPからのループバック攻撃をドロップ
        stateless_rule {
          priority = 10
          rule_definition {
            actions = ["aws:drop"]
            match_attributes {
              sources { address_definition = "127.0.0.0/8" }
              destinations { address_definition = "0.0.0.0/0" }
            }
          }
        }
        # ルール2: その他は全てステートフルルールへ転送
        stateless_rule {
          priority = 100
          rule_definition {
            actions = ["aws:forward_to_sfe"]
            match_attributes {
              sources { address_definition = "0.0.0.0/0" }
              destinations { address_definition = "0.0.0.0/0" }
            }
          }
        }
      }
    }
  }
}
```

#### 2. ステートフルルールグループ（ドメインリスト）: `amf-nfw-domain-rg`

```hcl
# ステートフルルール: ドメインベースフィルタリング（L7）
# 許可リスト方式（Allow List）を採用。
# デフォルト拒否にして、必要なドメインのみ許可する。
# これは「何でも通す」より「必要なものだけ通す」の原則に従う。
resource "aws_networkfirewall_rule_group" "domain_allowlist" {
  name     = "${var.prefix}-nfw-domain-rg"
  type     = "STATEFUL"
  capacity = 100

  rule_group {
    rules_source {
      rules_source_list {
        generated_rules_type = "ALLOWLIST"
        target_types         = ["HTTP_HOST", "TLS_SNI"]
        targets = [
          ".amazonaws.com",      # AWS サービスエンドポイント（SSM など）
          ".amazonlinux.com",    # OS アップデート
          "example.com",         # 疎通確認用
        ]
      }
    }
    # デフォルト拒否（ステートフルルールグループのデフォルトアクション）
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}
```

#### 3. ステートフルルールグループ（Suricata IPS）: `amf-nfw-ips-rg`

```hcl
# Suricata 互換ルールで SQL インジェクション・スキャン試行を検出
# action: drop でブロック、alert でログのみ
resource "aws_networkfirewall_rule_group" "ips" {
  name     = "${var.prefix}-nfw-ips-rg"
  type     = "STATEFUL"
  capacity = 200

  rule_group {
    rules_source {
      rules_string = <<-RULES
        # SQL インジェクション試行のブロック
        drop http any any -> any any (msg:"SQL Injection Attempt"; content:"SELECT"; nocase; content:"FROM"; nocase; sid:1000001; rev:1;)
        drop http any any -> any any (msg:"SQL Injection UNION"; content:"UNION"; nocase; content:"SELECT"; nocase; sid:1000002; rev:1;)
        # ディレクトリトラバーサル試行のブロック
        drop http any any -> any any (msg:"Directory Traversal"; content:"../"; sid:1000003; rev:1;)
        # 攻撃ツールのユーザーエージェント検出
        drop http any any -> any any (msg:"Nikto Scanner"; content:"Nikto"; http_header; sid:1000004; rev:1;)
      RULES
    }
    stateful_rule_options {
      rule_order = "STRICT_ORDER"
    }
  }
}
```

#### 4. Firewall Policy: `amf-nfw-policy`

```hcl
resource "aws_networkfirewall_firewall_policy" "main" {
  name = "${var.prefix}-nfw-policy"

  firewall_policy {
    # ステートレス: デフォルトはステートフルへ転送
    stateless_default_actions          = ["aws:forward_to_sfe"]
    stateless_fragment_default_actions = ["aws:forward_to_sfe"]

    stateless_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.stateless.arn
    }

    # ステートフル: STRICT_ORDER でルール適用順を制御
    stateful_engine_options {
      rule_order = "STRICT_ORDER"
    }

    stateful_rule_group_reference {
      priority     = 10
      resource_arn = aws_networkfirewall_rule_group.domain_allowlist.arn
    }
    stateful_rule_group_reference {
      priority     = 20
      resource_arn = aws_networkfirewall_rule_group.ips.arn
    }

    # デフォルト拒否（許可リストに載っていないものはブロック）
    stateful_default_actions = ["aws:drop_strict"]
  }
}
```

#### 5. Network Firewall 本体: `amf-nfw`

```hcl
resource "aws_networkfirewall_firewall" "main" {
  name                = "${var.prefix}-nfw"
  vpc_id              = var.vpc_id
  firewall_policy_arn = aws_networkfirewall_firewall_policy.main.arn

  # コスト最適化: ハンズオンのため 1AZ のみ
  # 本番では全 AZ に配置する（可用性 vs コストのトレードオフ）
  subnet_mapping {
    subnet_id = var.firewall_subnet_id_1a
  }

  delete_protection = false  # ハンズオン用: 削除しやすくする
}
```

#### 6. CloudWatch Logs への転送設定

```hcl
resource "aws_networkfirewall_logging_configuration" "main" {
  firewall_arn = aws_networkfirewall_firewall.main.arn

  logging_configuration {
    # アラートログ: ブロック・検知イベントを記録
    log_destination_config {
      log_type             = "ALERT"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.nfw_alert.name
      }
    }
    # フローログ: 全接続の記録（デバッグ用、コスト注意）
    log_destination_config {
      log_type             = "FLOW"
      log_destination_type = "CloudWatchLogs"
      log_destination = {
        logGroup = aws_cloudwatch_log_group.nfw_flow.name
      }
    }
  }
}
```

---

### terraform/modules/network_firewall/route_tables.tf

**重要**: Network Firewall のルートテーブル設定は最もつまずきやすいポイント。
以下のパターンを正確に実装すること。

```
# Traffic Chaining パターン（Ingress Inspection）
#
# ① Internet からの Ingress:
#    IGW → Firewall Endpoint → Public Subnet（EC2）
#
# ② EC2 からの Egress:
#    EC2（Public Subnet）→ Firewall Endpoint → IGW → Internet
#
# これを実現するために 3 つのルートテーブルを操作する：
# 1. IGW Route Table（Edge Association）: IGW にアタッチ
# 2. Firewall Subnet Route Table: Firewall Subnet から IGW へ
# 3. Public Subnet Route Table: Public Subnet から Firewall Endpoint へ
```

- `aws_route_table` "igw_rt":
  - IGW に **Edge Association** でアタッチ（`gateway_id` で関連付け）
  - ルート: `10.0.0.0/24`（Public Subnet）→ `firewall_endpoint_id`
  - コメント: `# IGW から Public Subnet 向けトラフィックを Firewall 経由にする`

- `aws_route_table` "firewall_rt":
  - Firewall Subnet にアタッチ
  - ルート: `0.0.0.0/0` → `igw_id`
  - コメント: `# Firewall Subnet からのトラフィックは直接 IGW へ（Firewall自身はFWを通らない）`

- Public Subnet の既存ルートテーブルを更新:
  - ルート: `0.0.0.0/0` → `firewall_endpoint_id`（IGW 直接ではなく Firewall 経由に変更）
  - コメント: `# Egress も Firewall を通過させるための核心ルート`

**Firewall Endpoint ID の取得**:
```hcl
# Network Firewall の Endpoint ID は apply 後に動的に決まる
# sync_states から AZ ごとの endpoint_id を取得する
locals {
  firewall_endpoint_id = tolist(
    aws_networkfirewall_firewall.main.firewall_status[0].sync_states
  )[0].attachment[0].endpoint_id
}
```

---

### outputs.tf

```hcl
output "firewall_arn" {
  value = aws_networkfirewall_firewall.main.arn
}
output "firewall_endpoint_id" {
  value = local.firewall_endpoint_id
}
output "nfw_alert_log_group" {
  value = aws_cloudwatch_log_group.nfw_alert.name
}
```

---

## environments/dev/main.tf への追記

```hcl
module "network_firewall" {
  source              = "../../modules/network_firewall"
  prefix              = var.prefix
  vpc_id              = module.vpc.vpc_id
  firewall_subnet_id_1a = module.vpc.firewall_subnet_ids["1a"]
  public_subnet_ids   = module.vpc.public_subnet_ids
  internet_gateway_id = module.vpc.internet_gateway_id
}
```

---

## 実行手順

```bash
cd terraform/environments/dev
terraform plan   # ルートテーブルの変更が含まれることを確認
terraform apply

# Firewall Endpoint の ID を確認
terraform output firewall_endpoint_id
```

---

## フェーズ完了の定義

- [ ] `terraform apply` がエラーなく完了する
- [ ] AWS コンソールで Network Firewall のステータスが "Ready" になっている
- [ ] ルートテーブルに Firewall Endpoint が設定されている（3つのRTを確認）
- [ ] 許可リスト外のドメインへの通信がブロックされる
  ```bash
  # SSM セッションから実行
  curl https://example.com       # → 成功するはず
  curl https://evil-site.example # → タイムアウトするはず
  ```
- [ ] CloudWatch Logs の `amf-nfw-alert` にブロックログが出力される

---

## 学習確認（Phase 2 終了後に自問）

**Q1**: Firewall Subnet が `/28`（16個のIPアドレス）で十分な理由は何か？
- Firewall Endpoint は何個の IP を使うか？

**Q2**: IGW Edge Association（IGW にルートテーブルをアタッチする）が必要な理由は？
- これをしないとどういうトラフィックフローになるか？

**Q3**: ステートレスルールで `aws:forward_to_sfe` にしたものが、
ステートフルルールでブロックされた場合、戻りトラフィックはどうなるか？

**Q4**: コスト観点で本番なら 2AZ、ハンズオンで 1AZ にした理由を説明できるか？
- 1AZ にした場合の可用性リスクは何か？