# ✅Phase 1: tfstate バックエンド初期化 + ネットワーク基盤構築

## このフェーズで実装するもの
- S3 バックエンド + DynamoDB ロックテーブルのブートストラップスクリプト
- Terraform モジュール: `network` (VPC, Subnet, IGW, NAT Gateway, NACL, VPC Flow Logs)
- `envs/prod` エントリーポイントの骨格

---

## 事前確認
まず CLAUDE.md を読み込んでプロジェクト規約を把握すること。
ディレクトリ構造が存在しない場合は CLAUDE.md の構造に従って作成すること。

---

## Step 1: ブートストラップスクリプト

`scripts/bootstrap.sh` を作成する。以下の要件を満たすこと：

```
要件:
- tfstate用S3バケット作成: s3t-prod-tfstate-{AWSアカウントID}
  - バージョニング有効
  - サーバーサイド暗号化 (SSE-S3、後でKMSに移行するため切り替えしやすい構造)
  - パブリックアクセス全ブロック
  - オブジェクトロック無効（ステートの上書きを許可）
- DynamoDBロックテーブル作成: s3t-prod-tfstate-lock
  - PAY_PER_REQUEST
  - ハッシュキー: LockID (String)
- スクリプトは冪等（既存リソースがあればスキップ）
- リージョン: ap-northeast-1
- 実行後に terraform init 用のバックエンド設定ブロックを標準出力に表示
```

---

## Step 2: Terraform バックエンド設定

`terraform/envs/prod/backend.tf` を作成：

```
要件:
- S3バックエンド設定
- encrypt = true
- DynamoDB ロック設定
- key: "prod/terraform.tfstate"
```

---

## Step 3: network モジュール

`terraform/modules/network/` を作成。以下のファイル構成：
- `main.tf`
- `variables.tf`
- `outputs.tf`

### VPC 設計（上級要件）

```
CIDR: 172.16.0.0/16

サブネット構成 (ap-northeast-1a, 1c, 1d の3AZ):
- Public Subnet:  172.16.0.0/24, 172.16.1.0/24, 172.16.2.0/24
- Private Subnet: 172.16.10.0/24, 172.16.11.0/24, 172.16.12.0/24  ← EC2配置
- Data Subnet:    172.16.20.0/24, 172.16.21.0/24, 172.16.22.0/24  ← RDS配置

NAT Gateway: 各AZに1台（高可用性、コストコメントを必ず記載）
Elastic IP: NAT Gateway用に3つ
```

### VPC Flow Logs（上級要件）

```
要件:
- CloudWatch Logs グループ: /aws/vpc/flowlogs/ata-prod
  - 保持期間: 90日
- IAM Role: s3t-prod-vpc-flowlogs-role
  - 最小権限: logs:CreateLogGroup, logs:CreateLogDeliveryを禁止
  - 許可: logs:CreateLogStream, logs:PutLogEvents, logs:DescribeLogGroups, logs:DescribeLogStreams のみ
- すべてのトラフィック (ACCEPT/REJECT両方) を記録
- [セキュリティ] コメント: セキュリティインシデント調査・不正アクセス検知のため
```

### NACL（上級要件）

```
Public Subnet NACL:
- インバウンド: 80(HTTP), 443(HTTPS), 1024-65535(エフェメラルポート) を 0.0.0.0/0 から許可
- アウトバウンド: すべて許可
- [設計意図] SG との2段階防御。NACLはステートレスなのでエフェメラルポートの明示が必要

Private Subnet NACL:
- インバウンド: VPC CIDR (172.16.0.0/16) からのみ許可
- アウトバウンド: 443(HTTPS to AWS APIs), 1024-65535 を 0.0.0.0/0 へ許可
  [設計意図] EC2→Secrets Manager/SSM等のAWS APIはNAT経由のHTTPS

Data Subnet NACL:
- インバウンド: Private Subnet CIDRs (172.16.10.0/24-172.16.12.0/24) からポート3306のみ
- アウトバウンド: Private Subnet CIDRs へポート3306のみ
- [セキュリティ] データ層は最大限に閉じる。管理トラフィックも通さない
```

### common_tags と outputs

```hcl
// locals に common_tags を定義
locals {
  common_tags = {
    Project     = "secure-3tier-iac-pipeline"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = var.owner
  }
}

// outputs: vpc_id, public_subnet_ids, private_subnet_ids, data_subnet_ids
// outputs は他モジュールから参照するため全て出力すること
```

---

## Step 4: envs/prod エントリーポイント骨格

`terraform/envs/prod/main.tf` を作成：

```
- network モジュールを呼び出す
- required_providers: aws >= 5.40
- required_version: >= 1.7
- provider: ap-northeast-1
- variables.tf: environment="prod", owner, aws_account_id
- outputs.tf: network モジュールの主要出力をパススルー
```

---

## Step 5: 動作確認用コマンドをREADMEに記載

`terraform/envs/prod/README.md` を作成し以下を記載：
1. bootstrap.sh の実行方法
2. terraform init → plan → apply の手順
3. VPC Flow Logs の確認方法（CloudWatch Logs Insights クエリ例付き）
4. よくあるエラーと対処法（NAT Gateway の料金について注意書き含む）

---

## 完了条件
- [ ] scripts/bootstrap.sh が存在し実行権限がある
- [ ] terraform/modules/network/ に main.tf, variables.tf, outputs.tf がある
- [ ] NACL が Public/Private/Data の3種類定義されている
- [ ] VPC Flow Logs が CloudWatch Logs に送られる設定になっている
- [ ] IMDSv2 に関するコメントが main.tf に含まれている（Phase2への橋渡し）
- [ ] common_tags が全リソースに適用されている
- [ ] `terraform validate` が通る構造になっている

## 次フェーズへの引き継ぎ情報
このフェーズ完了後、以下の値が outputs として利用可能になる：
- vpc_id
- public_subnet_ids (list, 3要素)
- private_subnet_ids (list, 3要素)
- data_subnet_ids (list, 3要素)
これらは Phase 2 の security/compute モジュールで参照する。