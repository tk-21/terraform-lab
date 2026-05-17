# ✅Phase 1: VPC / Security Group / NACL 構築

## このフェーズの目標

- ネットワークの土台となる VPC・サブネット・ルートテーブルを Terraform で構築する
- Security Group（ステートフル）と NACL（ステートレス）の **設計上の役割の違い** を
  Terraform コードの構造として表現する
- VPC Flow Logs を有効化し、後続フェーズの通信検証基盤を整える
- EC2 インスタンスを最小構成で起動し、Session Manager 経由でアクセスできる状態を作る

---

## 前提確認

以下が存在することを確認してから着手すること：

- `CLAUDE.md` が読み込まれていること（命名規則・タグ・CIDR 設計を参照）
- AWS CLI が設定済みで `ap-northeast-1` に対してアクションできること
- Terraform 1.7 以上がインストール済みであること
- S3 バケット（tfstate 用）と DynamoDB テーブル（state lock 用）が事前に作成済みであること
  - バケット名: `amf-tfstate-{AWS_ACCOUNT_ID}`
  - テーブル名: `amf-tfstate-lock`

---

## 生成対象ファイル

### terraform/backend.tf

```
S3 バックエンドの設定。
bucket / key / region / dynamodb_table を記載。
encrypt = true を必須とする。
```

### terraform/modules/vpc/

**main.tf**
- `aws_vpc`: `10.0.0.0/16`、DNS ホスト名有効化
- `aws_subnet` × 6:
  - Public: `10.0.0.0/24`（1a）、`10.0.1.0/24`（1c）
  - Private: `10.0.10.0/24`（1a）、`10.0.11.0/24`（1c）
  - Firewall: `10.0.100.0/28`（1a）、`10.0.101.0/28`（1c）
  - ※ Firewall Subnet は Phase 2 で使用するが、今フェーズで作成しておく
- `aws_internet_gateway`: Public サブネット向け
- `aws_route_table` × 2: Public 用・Private 用
- `aws_route_table_association`: 各サブネットに関連付け
- `aws_flow_log`: VPC Flow Logs を CloudWatch Logs へ出力
  - `traffic_type = "ALL"` で許可・拒否両方を記録
  - ログ保持期間: 7日（コスト考慮）
- `aws_cloudwatch_log_group` + `aws_iam_role`（Flow Logs 用）

**variables.tf** / **outputs.tf**
- outputs には vpc_id, subnet_id 系を全て出力すること（後続モジュールで参照）

---

### terraform/modules/security_group/

**設計方針（コメントとして main.tf に記載すること）**:
```
# Security Group はステートフルなファイアウォール。
# 戻りトラフィックを自動的に許可するため、outbound に明示的な許可は最小限でよい。
# インスタンスの役割（Web/App/Bastion）ごとに SG を分け、
# リソース間参照（SG ID 参照）を使って最小権限を表現する。
```

**main.tf** — 以下の SG を作成：

1. `amf-sg-web` — ALB/外部向け Web 層
   - ingress: 80（HTTP）, 443（HTTPS）from `0.0.0.0/0` ← WAF 経由を想定
   - egress: 8080 to `amf-sg-app`（SG 参照）

2. `amf-sg-app` — アプリケーション層
   - ingress: 8080 from `amf-sg-web`（SG 参照）
   - egress: 443 to `0.0.0.0/0`（外部 API 呼び出し想定）

3. `amf-sg-ssm` — Session Manager 用（EC2 に付与）
   - ingress: なし（SSM はアウトバウンドのみで動作）
   - egress: 443 to `0.0.0.0/0`（SSM エンドポイント通信）
   - コメント: `# SSM は EC2 からのアウトバウンド 443 のみで動作する。インバウンド不要。`

**variables.tf** / **outputs.tf**

---

### terraform/modules/nacl/

**設計方針（コメントとして main.tf に記載すること）**:
```
# NACL はステートレスなサブネットレベルのファイアウォール。
# 戻りトラフィック（エフェメラルポート: 1024-65535）を
# 明示的に許可しなければ通信が成立しない点が SG との最大の違い。
# NACL は SG の補完として使用し、サブネット間の大雑把なトラフィック制御に用いる。
# ルール番号は 100 刻みにして後から挿入できる余地を持たせる。
```

**main.tf** — 以下の NACL を作成：

1. `amf-nacl-public` — Public サブネット用
   - インバウンド:
     - 100: 許可 TCP 80 from `0.0.0.0/0`
     - 110: 許可 TCP 443 from `0.0.0.0/0`
     - 120: 許可 TCP 1024-65535 from `0.0.0.0/0`（エフェメラルポート）
     - 200: 拒否 TCP 22 from `0.0.0.0/0`（SSH 明示的拒否）
     - 32766: 許可 ALL（デフォルト許可、最後に）
   - アウトバウンド:
     - 100: 許可 ALL to `0.0.0.0/0`

2. `amf-nacl-private` — Private サブネット用
   - インバウンド:
     - 100: 許可 TCP 8080 from `10.0.0.0/23`（Public サブネット範囲）
     - 110: 許可 TCP 1024-65535 from `0.0.0.0/0`（エフェメラルポート）
     - 32766: 許可 ALL
   - アウトバウンド:
     - 100: 許可 ALL to `0.0.0.0/0`

---

### terraform/modules/ec2_ssm/ （新規モジュール）

**目的**: Session Manager でアクセスできる検証用 EC2 を最小構成で起動する

**main.tf**:
- `aws_instance`:
  - AMI: Amazon Linux 2023（SSM Agent 同梱）の最新版を `data` で取得
  - インスタンスタイプ: `t4g.nano`（arm64/Graviton、コスト最小）
  - サブネット: Private サブネット（1a）
  - SG: `amf-sg-ssm`
  - `metadata_options.http_tokens = "required"`（IMDSv2 強制）
  - `iam_instance_profile`: SSM 用 Instance Profile を付与
- `aws_iam_role` + `aws_iam_role_policy_attachment`:
  - `AmazonSSMManagedInstanceCore` ポリシーをアタッチ
  - コメント: `# SSM Agent の動作に必要な最小ポリシー。EC2 への直接 SSH は禁止。`
- `aws_iam_instance_profile`

---

### terraform/environments/dev/

**main.tf** — 全モジュールを呼び出す
- module "vpc" / "security_group" / "nacl" / "ec2_ssm" を接続

**variables.tf**:
```hcl
variable "environment" {
  default = "dev"
}
variable "prefix" {
  default = "amf"
}
variable "aws_region" {
  default = "ap-northeast-1"
}
```

**terraform.tfvars**: 上記変数の値を記載

**outputs.tf**: vpc_id, subnet IDs, SG IDs, EC2 instance ID を出力

---

## 実行手順（コメントとして runbook に記載すること）

```bash
cd terraform/environments/dev
terraform init
terraform plan   # 必ず差分確認してから apply
terraform apply
```

---

## フェーズ完了の定義

以下が全て満たされたら Phase 1 完了とする：

- [ ] `terraform apply` がエラーなく完了する
- [ ] AWS コンソールで VPC / サブネット / SG / NACL が確認できる
- [ ] VPC Flow Logs が CloudWatch Logs に出力されている
- [ ] Session Manager から EC2 にアクセスできる（SSH 不使用）
- [ ] EC2 から `curl https://example.com` が通る（外部疎通確認）
- [ ] NACL のルール番号設計の理由を口頭で説明できる

---

## 学習確認（Phase 1 終了後に自問）

**Q1**: Security Group の "ステートフル" とは具体的にどういう挙動か？
- EC2 から外部へ TCP 443 でリクエストを送った後、戻りパケットが来るとき SG はどう判断するか？

**Q2**: NACL でエフェメラルポート（1024-65535）を許可しなかった場合、何が起きるか？
- どのトラフィックが壊れるか？なぜか？

**Q3**: Private サブネットの EC2 に SSM でアクセスできる理由を図で説明できるか？
- どのエンドポイントに対してどのポートでつながっているか？