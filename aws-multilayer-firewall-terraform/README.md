# aws-multilayer-firewall-terraform

AWS のネットワークセキュリティ機能（NACL / Security Group / AWS Network Firewall / WAF）を
Terraform で段階的に構築し、実際の攻撃をブロックする動作を確認するハンズオン。

---

## このハンズオンで得られること

### 知識

| 問い | ハンズオンで答えられるようになること |
|---|---|
| SG と NACL はどう使い分けるのか？ | ステートフル/ステートレスの挙動を実際に確かめ、「SG を主軸・NACL を補完」の根拠を説明できる |
| Network Firewall はどこに置くのか？ | Sandwich ルーティング（IGW Edge RT の仕組み）を自分で設定し、なぜ 3 種類のルートテーブルが必要かを説明できる |
| WAF のルールはどう設計するのか？ | Priority・WCU・COUNT モードの関係を理解し、誤検知を出さずにマネージドルールを導入する手順を説明できる |
| SQLi はどのレイヤーでブロックされるのか？ | NFW IPS（Suricata）と WAF CRS の役割分担を、実際の攻撃シミュレーション結果を見ながら説明できる |
| 本番環境にするには何が足りないのか？ | Multi-AZ NFW・Shield・GuardDuty など、追加すべき要素をコスト感と合わせて判断できる |

### スキル

- Terraform で AWS ネットワークセキュリティリソースを宣言的に管理する
- `terraform plan` の差分を読んで意図通りの変更かを判断する
- SSM Session Manager で EC2 にアクセスし、通信疎通を確認する
- CloudWatch Logs でセキュリティイベント（NFW ブロック・WAF ブロック）を調査する
- ADR（Architecture Decision Record）で設計判断の根拠を言語化する

### 成果物

- 動く多層防御インフラ（Terraform コード一式）
- 3 本の ADR（NACL/SG・NFW 配置・WAF 戦略）
- ポートフォリオとして GitHub に公開できる品質のドキュメント

---

## アーキテクチャ概要

```
           Internet
              │
              ▼
   [Internet Gateway]
              │  ← IGW Edge Route Table が Ingress を NFW へ誘導
              ▼
   [AWS Network Firewall]   L3-L7: ドメイン許可リスト / Suricata IPS
              │
              ▼
   [NACL: amf-nacl-public]  サブネット境界・SSH の明示的 DENY
              │
              ▼
   [ALB + WAF WebACL]       SQLi / XSS / Bot / レートベース
              │
              ▼
   [NACL: amf-nacl-private] Public Subnet からの 8080 のみ許可
              │
              ▼
   [EC2 (Private Subnet)]   Security Group でロールベース制御
              │
              ▼
   [SSM Session Manager]    SSH レス・22番ポート不使用
```

詳細な図と設計解説 → [ARCHITECTURE.md](ARCHITECTURE.md)

---

## 前提条件

### 必須ツール

以下のバージョンを確認してから進むこと。

```bash
# Terraform 1.7 以上
terraform version
# => Terraform v1.x.x

# AWS CLI v2
aws --version
# => aws-cli/2.x.x

# Session Manager Plugin（EC2 アクセスに必要）
session-manager-plugin --version
# => 1.x.x.x
```

Session Manager Plugin が未インストールの場合:
```bash
# macOS
brew install --cask session-manager-plugin

# Linux (x86_64)
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
```

### AWS 認証

```bash
# プロファイルが設定されていることを確認
aws sts get-caller-identity --region ap-northeast-1
# => { "UserId": "...", "Account": "123456789012", "Arn": "..." }
```

### 必要な IAM 権限

ハンズオン実施者の IAM ユーザー/ロールに以下が必要:
- `ec2:*`（VPC / Subnet / SG / NACL / IGW）
- `network-firewall:*`
- `wafv2:*`
- `elasticloadbalancing:*`
- `ssm:*` / `ssmmessages:*` / `ec2messages:*`
- `iam:*`（ロール・ポリシーの作成）
- `logs:*`（CloudWatch Logs）
- `s3:*`（Terraform State 用）
- `dynamodb:*`（State Lock 用）

---

## 事前準備：Terraform バックエンドの作成

**Terraform の State ファイルを保存する S3 バケットと DynamoDB テーブルを手動で作成する。**
（これらは Terraform 管理外のリソース。一度だけ実行すれば OK。）

### 1. AWS アカウント ID を確認する

```bash
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${AWS_ACCOUNT_ID}"
```

### 2. S3 バケットを作成する（tfstate 保存用）

```bash
# バケット名は全世界でユニークである必要がある
BUCKET_NAME="amf-tfstate-${AWS_ACCOUNT_ID}"

aws s3api create-bucket \
  --bucket "${BUCKET_NAME}" \
  --region ap-northeast-1 \
  --create-bucket-configuration LocationConstraint=ap-northeast-1

# バージョニングを有効化（State の誤削除に備える）
aws s3api put-bucket-versioning \
  --bucket "${BUCKET_NAME}" \
  --versioning-configuration Status=Enabled

# 暗号化を有効化
aws s3api put-bucket-encryption \
  --bucket "${BUCKET_NAME}" \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# パブリックアクセスをブロック
aws s3api put-public-access-block \
  --bucket "${BUCKET_NAME}" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

echo "S3 バケット作成完了: ${BUCKET_NAME}"
```

### 3. DynamoDB テーブルを作成する（State Lock 用）

```bash
aws dynamodb create-table \
  --table-name amf-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-northeast-1

echo "DynamoDB テーブル作成完了: amf-tfstate-lock"
```

### 4. backend.tf にアカウント ID を設定する

```bash
# REPLACE_WITH_ACCOUNT_ID を実際の値に置き換える
sed -i "s/REPLACE_WITH_ACCOUNT_ID/${AWS_ACCOUNT_ID}/" \
  terraform/environments/dev/backend.tf

# 確認
cat terraform/environments/dev/backend.tf
```

---

## ハンズオン実行手順

### Step 1: リポジトリをクローンしてディレクトリに移動

```bash
git clone <このリポジトリの URL>
cd aws-multilayer-firewall-terraform
```

### Step 2: Terraform を初期化する

```bash
cd terraform/environments/dev

terraform init
```

成功すると以下のような出力が出る:
```
Initializing the backend...
Successfully configured the backend "s3"!

Initializing provider plugins...
- Installing hashicorp/aws v5.x.x...

Terraform has been successfully initialized!
```

> ⚠️ `Error: Failed to get existing workspaces` が出た場合は backend.tf の
> バケット名が正しいか、S3 バケットが作成済みかを確認すること。

### Step 3: 差分を確認する（必ず実施）

```bash
terraform plan -var-file="terraform.tfvars"
```

**確認すべきポイント:**
- `Plan: XX to add, 0 to change, 0 to destroy.` の数が想定通りか
- 予期しない `destroy` が含まれていないか
- セキュリティグループのポートが意図通りか

```
# 期待される出力例（初回適用時）
Plan: 45 to add, 0 to change, 0 to destroy.
```

### Step 4: インフラを構築する

```bash
terraform apply -var-file="terraform.tfvars"
```

`Do you want to perform these actions?` のプロンプトで `yes` を入力する。

完了まで **5〜10 分**かかる（Network Firewall のプロビジョニングに時間がかかる）。

成功時の出力例:
```
Apply complete! Resources: 45 added, 0 changed, 0 destroyed.

Outputs:

alb_dns_name     = "amf-alb-xxxxxxxxx.ap-northeast-1.elb.amazonaws.com"
ec2_instance_id  = "i-0123456789abcdef0"
ec2_private_ip   = "10.0.10.xxx"
waf_log_group    = "aws-waf-logs-amf-alb"
...
```

### Step 5: 出力値を環境変数に保存する

```bash
# 以降のコマンドで使うため変数に格納しておく
INSTANCE_ID=$(terraform output -raw ec2_instance_id)
ALB_DNS=$(terraform output -raw alb_dns_name)

echo "Instance ID : ${INSTANCE_ID}"
echo "ALB DNS     : ${ALB_DNS}"
```

---

## 動作確認

### 確認 1: ALB への正常アクセス

ブラウザまたは curl で ALB にアクセスし、200 が返ることを確認する。

```bash
curl -i "http://${ALB_DNS}/"
# => HTTP/1.1 200 OK
# => amf-lab: OK
```

### 確認 2: WAF ブロック動作（Attack Simulation）

```bash
# リポジトリのルートに戻る
cd ../../..

# 実行権限を付与（初回のみ）
chmod +x scripts/attack_simulation.sh

# 模擬攻撃スクリプトを実行
./scripts/attack_simulation.sh "${ALB_DNS}"
```

**期待される出力:**
```
======================================
WAF・Network Firewall ブロック動作確認
Target: http://amf-alb-xxx.elb.amazonaws.com
======================================

--- SQL インジェクション試行 ---
✅ BLOCKED (403): Classic OR-based SQLi
✅ BLOCKED (403): SELECT FROM SQLi
✅ BLOCKED (403): UNION SELECT SQLi
✅ BLOCKED (403): DROP TABLE SQLi

--- XSS 試行 ---
✅ BLOCKED (403): Reflected XSS (script tag)
...

--- スキャナー UA 試行 ---
✅ BLOCKED (403): WAF カスタムルール: sqlmap/1.7
...
```

### 確認 3: SSM 経由の疎通確認（NFW ドメインフィルタリング）

```bash
chmod +x scripts/test_connectivity.sh

./scripts/test_connectivity.sh "${INSTANCE_ID}" "${ALB_DNS}"
```

**期待される出力:**
```
======================================
Network Security Lab - 疎通確認テスト
Instance: i-0123456789abcdef0
======================================

--- Network Firewall ドメインフィルタリング ---

=== TEST: 許可ドメイン: example.com (HTTPS 200 のはず) ===
✅ PASS: 許可ドメイン: example.com (status: Success, output: 200)

=== TEST: 拒否ドメイン: evil-site.test (NFW がドロップ → タイムアウトするはず) ===
✅ PASS (expected failure): 拒否ドメイン: evil-site.test

--- WAF 動作確認 ---
✅ PASS: 正常リクエスト: ALB アクセス (200 OK のはず)
✅ PASS: WAF ブロック: sqlmap UA (403 のはず)
...

PASS: 8
FAIL: 0
```

### 確認 4: CloudWatch Logs でブロックログを確認

マネジメントコンソールで以下のロググループを開く:

| ログ種別 | Log Group 名 | 確認内容 |
|---|---|---|
| WAF ブロック | `aws-waf-logs-amf-alb` | `terminatingRuleId` でどのルールが発動したか |
| NFW アラート | `/aws/network-firewall/amf-nfw/alert` | `event.action: blocked` でブロックされた通信先 |
| VPC Flow | `/aws/vpc/flow-log/amf-vpc` | `action=REJECT` で NACL/SG によるブロック |

**CLI で確認する場合:**
```bash
# WAF ブロックログ（直近 1 時間）
aws logs filter-log-events \
  --log-group-name "aws-waf-logs-amf-alb" \
  --start-time $(date -d '1 hour ago' +%s000 2>/dev/null || date -v-1H +%s000) \
  --filter-pattern '{ $.action = "BLOCK" }' \
  --region ap-northeast-1 \
  --query "events[].message" \
  --output text | python3 -m json.tool 2>/dev/null | grep terminatingRuleId | head -20

# NFW ブロックログ（直近 1 時間）
aws logs filter-log-events \
  --log-group-name "/aws/network-firewall/amf-nfw/alert" \
  --start-time $(date -d '1 hour ago' +%s000 2>/dev/null || date -v-1H +%s000) \
  --region ap-northeast-1 \
  --query "events[].message" \
  --output text
```

### 確認 5: SSM でEC2 にログインして直接疎通確認

```bash
# Session Manager でセッションを開始
aws ssm start-session \
  --target "${INSTANCE_ID}" \
  --region ap-northeast-1
```

EC2 の bash から以下を試す:

```bash
# 許可ドメイン: 通るはず
curl -s -o /dev/null -w "%{http_code}" https://example.com --max-time 10
# => 200

# 許可ドメイン: amazonaws.com は許可リストにある
curl -s -o /dev/null -w "%{http_code}" https://s3.amazonaws.com --max-time 10
# => 200 or 403 (S3 は認証なしだと 403 だが通信は成立している)

# 禁止ドメイン: NFW がドロップするため接続できない
curl -s -o /dev/null --max-time 10 https://github.com
# => タイムアウト (Network Firewall が DROP)
```

> **ポイント**: EC2 からのアウトバウンドは Network Firewall 経由。
> `evil-site.test` や `github.com` など許可リスト外のドメインは NFW がドロップする。

---

## トラブルシューティング

### `terraform init` で Backend エラーが出る

```
Error: Failed to get existing workspaces: S3 bucket does not exist
```

→ 事前準備の S3 バケット作成手順が完了しているか確認する。
   バケット名が `amf-tfstate-{AWS_ACCOUNT_ID}` になっているか確認する。

```bash
aws s3 ls | grep amf-tfstate
```

### `terraform apply` で NFW のタイムアウトエラーが出る

```
Error: waiting for NetworkFirewall Firewall creation: timeout
```

→ Network Firewall のプロビジョニングは 5〜10 分かかる場合がある。
  もう一度 `terraform apply` を実行すると続きから再開できる。

### SSM でセッションが開始できない

```
SessionManagerPlugin is not found.
```

→ Session Manager Plugin が未インストール。「前提条件」の手順でインストールする。

| エラー / 症状 | 原因 | 対処 |
|---|---|---|
| `Target i-xxx is not connected.` | SSM Agent 未起動、または起動直後 | 1〜2 分待って再試行。それでも繋がらない場合は EC2 を再起動 |
| セッション開始できない（エラーなし） | VPC Endpoint が未作成またはヘルス異常 | `aws ec2 describe-vpc-endpoints --filters "Name=tag:Project,Values=aws-multilayer-firewall-terraform"` でステータス確認 |
| `RequestExpired` | EC2 と SSM のシステム時刻のずれ | EC2 内で `chronyc status` を確認し、ntpd/chrony を再起動 |

### WAF テストで 200 が返ってしまう（ブロックされない）

- `curl` コマンドのペイロードがシェルにより変換されている可能性がある。
  シングルクォートでエスケープされているか確認する。
- WAF WebACL が ALB に正しくアタッチされているか確認する:
  ```bash
  aws wafv2 list-web-acls --scope REGIONAL --region ap-northeast-1
  aws wafv2 get-web-acl-for-resource \
    --resource-arn $(aws elbv2 describe-load-balancers \
      --names amf-alb --query "LoadBalancers[0].LoadBalancerArn" --output text \
      --region ap-northeast-1) \
    --region ap-northeast-1
  ```

---

## 環境の削除（コスト節約）

**ハンズオン終了後は必ず実行すること。** 放置すると Network Firewall だけで月 $284 かかる。

```bash
cd terraform/environments/dev

# 削除前に何が消えるかを必ず確認する
terraform plan -destroy -var-file="terraform.tfvars"

# 削除を実行
terraform destroy -var-file="terraform.tfvars"
```

`Destroy complete! Resources: 45 destroyed.` が出れば完了。

削除後に念のため確認:
```bash
# NFW が削除されていることを確認（課金が止まる最重要リソース）
aws network-firewall list-firewalls --region ap-northeast-1
# => { "Firewalls": [] }

# VPC Endpoint が削除されていることを確認
aws ec2 describe-vpc-endpoints \
  --filters "Name=tag:Project,Values=aws-multilayer-firewall-terraform" \
  --query "VpcEndpoints[?State!='deleted'].VpcEndpointId" \
  --region ap-northeast-1
# => []
```

> **バックエンドの S3・DynamoDB は削除しない。**
> 次回ハンズオン時に再利用できる。削除したい場合は手動で行うこと。

---

## 運用操作

ハンズオン中に発生しやすい操作手順をまとめる。

### WAF への緊急 IP ブロック追加

悪意ある IP を即時ブロックしたい場合の手順。

```bash
# IP セット ID と現在の LockToken を取得
IP_SET_ID=$(aws wafv2 list-ip-sets \
  --scope REGIONAL --region ap-northeast-1 \
  --query "IPSets[?Name=='amf-waf-blocked-ips'].Id" --output text)

LOCK_TOKEN=$(aws wafv2 get-ip-set \
  --scope REGIONAL --region ap-northeast-1 \
  --id "${IP_SET_ID}" --name amf-waf-blocked-ips \
  --query "LockToken" --output text)

# IP を追加（複数指定可）
aws wafv2 update-ip-set \
  --scope REGIONAL --region ap-northeast-1 \
  --id "${IP_SET_ID}" --name amf-waf-blocked-ips \
  --lock-token "${LOCK_TOKEN}" \
  --addresses "1.2.3.4/32" "5.6.7.8/32"
```

> ⚠️ これは Terraform 管理外の変更になる。後で `terraform/environments/dev/terraform.tfvars` の
> `blocked_ip_list` に反映し、`terraform apply` で状態を同期すること。

恒久的に追加する場合は Terraform で管理する:

```hcl
# terraform/environments/dev/terraform.tfvars
blocked_ip_list = ["1.2.3.4/32", "5.6.7.8/32"]
```

### NFW ドメイン許可リストの更新

EC2 から新しいドメインへの通信を許可したい場合（例: パッケージリポジトリ追加）。

`terraform/modules/network_firewall/main.tf` の `targets` リストを編集する:

```hcl
targets = [
  ".amazonaws.com",
  ".amazonlinux.com",
  "example.com",
  ".your-new-domain.com",  # ← 追加
]
```

差分確認してから適用:

```bash
cd terraform/environments/dev
terraform plan -var-file="terraform.tfvars"
terraform apply -var-file="terraform.tfvars"
```

> ルールグループの更新は数秒〜30 秒で即時反映される。Downtime は発生しない。

### 月次コスト確認

```bash
# 直近 30 日のプロジェクト別コストを確認
aws ce get-cost-and-usage \
  --time-period \
    Start=$(date -d '30 days ago' +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d),\
End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --filter '{"Tags":{"Key":"Project","Values":["aws-multilayer-firewall-terraform"]}}' \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region ap-northeast-1 \
  --query "ResultsByTime[].Groups[].{Service:Keys[0],Cost:Metrics.UnblendedCost.Amount}" \
  --output table
```

マネジメントコンソールで確認する場合:
1. [AWS Cost Explorer](https://console.aws.amazon.com/cost-management/home) を開く
2. フィルター → タグ → `Project = aws-multilayer-firewall-terraform`
3. グループ化: 「サービス別」／ 期間: 「月別」

---

## ディレクトリ構成

```
aws-multilayer-firewall-terraform/
├── ARCHITECTURE.md            # 完全理解ドキュメント（設計図・フロー・モジュール構成）
├── README.md                  # このファイル
├── terraform/
│   ├── modules/
│   │   ├── vpc/               # VPC / Subnet / IGW / VPC Endpoint / Flow Logs
│   │   ├── security_group/    # amf-sg-web / app / ssm / vpce
│   │   ├── nacl/              # Public / Private NACL ルール
│   │   ├── network_firewall/  # NFW 本体 / Policy / Rule Group / Route Tables
│   │   ├── alb/               # ALB（WAF のアタッチ先）
│   │   └── waf/               # WAF WebACL / IP Set / Logging
│   └── environments/
│       └── dev/
│           ├── main.tf        # モジュール呼び出し
│           ├── variables.tf
│           ├── outputs.tf
│           ├── terraform.tfvars
│           └── backend.tf     # S3 バックエンド設定
├── scripts/
│   ├── test_connectivity.sh   # SSM 経由の NFW・WAF 疎通確認テスト
│   └── attack_simulation.sh   # WAF ブロック動作の模擬攻撃確認
├── docs/
│   └── adr/
│       ├── 001_nacl_vs_sg.md
│       ├── 002_network_firewall_placement.md
│       └── 003_waf_rule_strategy.md
└── phases/                    # フェーズ別の Claude Code プロンプト
    ├── phase1.md              # VPC + SG + NACL
    ├── phase2.md              # Network Firewall
    ├── phase3.md              # WAF
    └── phase4.md              # 動作検証 + ドキュメント整備
```

---

## コスト目安

| リソース | 月額（常時稼働） | 4 時間ハンズオン |
|---|---|---|
| Network Firewall Endpoint (1AZ) | ~$284 | ~$1.6 |
| VPC Interface Endpoint × 3 | ~$30 | ~$0.2 |
| ALB | ~$6 | ~$0.04 |
| EC2 t4g.nano | ~$4 | ~$0.02 |
| CloudWatch Logs 等 | ~$2 | ~$0.01 |
| **合計** | **~$326/月** | **~$2** |

> ⚠️ **ハンズオン後は必ず `terraform destroy` を実行すること。**

---

## 設計判断（ADR）

各レイヤーの設計判断の根拠を ADR にまとめている。

- [ADR 001: NACL vs Security Group の役割分担](docs/adr/001_nacl_vs_sg.md)
  — ステートフル/ステートレスの具体的な挙動と使い分けの根拠
- [ADR 002: Network Firewall の配置場所と AZ 数](docs/adr/002_network_firewall_placement.md)
  — Sandwich ルーティングの仕組みと 1AZ に絞る理由（コスト vs 可用性）
- [ADR 003: WAF ルールの優先度戦略](docs/adr/003_waf_rule_strategy.md)
  — マネージドルールの選択・WCU 設計・COUNT モードで安全に導入する手順

---

## 参考リンク

- [ARCHITECTURE.md](ARCHITECTURE.md) — 本プロジェクトの設計詳細（必読）
- [AWS Network Firewall Developer Guide](https://docs.aws.amazon.com/network-firewall/latest/developerguide/)
- [AWS WAF Developer Guide](https://docs.aws.amazon.com/waf/latest/developerguide/)
- [VPC Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)
- [Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html)
