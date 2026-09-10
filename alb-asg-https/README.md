# ALB + Auto Scaling + HTTPS on AWS

Terraform で、インターネット公開する Web サービスの基本構成を作るサンプルです。ALB を唯一の公開点とし、Web サーバーは private subnet の Auto Scaling Group（ASG）で稼働します。ACM と Route 53 による HTTPS、AWS WAF のマネージドルールも含みます。

> 学習・検証・PoC 向けの構成です。NAT Gateway、ALB、WAF、EC2 は利用量に応じて課金されます。不要になったリソースは、内容を確認したうえで必ず削除してください。

## アーキテクチャ

```text
Internet
   |
   v
Route 53（A Alias）──> Application Load Balancer（public subnet）
                             |  :80  HTTP
                             |  :443 HTTPS（任意）
                             v
                       Target Group
                             |
                             v
                 Auto Scaling Group（private subnet）
                    └── Amazon Linux 2023 + nginx
                             |
                             v
                        NAT Gateway

ACM ── Route 53 による DNS 検証 ──> HTTPS 証明書
WAF ── AWS マネージドルール ───────> ALB
S3 Gateway VPC Endpoint ───────────> private route table
```

## 作成されるリソース

| モジュール | 作成するリソースと役割 |
| --- | --- |
| `network` | VPC、2 つずつの public/private subnet、Internet Gateway、NAT Gateway、route table、S3 Gateway VPC Endpoint |
| `alb` | インターネット向け ALB、target group、ALB 用／Web インスタンス用 security group |
| `asg_web` | Launch Template、Amazon Linux 2023 + nginx のインスタンス、ASG、ターゲット追跡スケーリングポリシー |
| `acm_r53` | ACM 証明書、Route 53 の DNS 検証レコード、ALB を向く A Alias レコード |
| `waf_alb` | AWS Managed Common Rule Set と Known Bad Inputs Rule Set を含むリージョナル WAF Web ACL |

ASG は 2 つの private subnet に分散し、既定では `t3.micro` を 2〜4 台起動します。平均 CPU 使用率 50%、および ALB のターゲットあたりリクエスト数 100 を目標値に自動スケーリングします。Launch Template では IMDSv2 を必須化し、Web 用 security group は ALB からの HTTP だけを許可します。SSH は既定で無効です。

## ディレクトリ構成

```text
.
├── main.tf                 # モジュールの組み立て
├── variables.tf            # ルートモジュールの入力変数
├── terraform.tfvars        # 環境固有の値（機密情報は置かない）
├── outputs.tf              # デプロイ後に参照する値
└── modules/
    ├── network/
    ├── alb/
    ├── asg_web/
    ├── acm_r53/
    └── waf_alb/
```

## 前提条件

- Terraform `~> 1.6`
- 上記リソースを作成できる AWS 認証情報
- `domain_name` を管理する既存の Route 53 パブリックホストゾーン
- そのホストゾーンへ委任済みのドメイン
- 対象 AWS アカウントに設定済みの AWS CLI（推奨）

作業前に、対象アカウントであることを確認してください。

```bash
aws sts get-caller-identity
```

## 設定

`terraform.tfvars` に値を設定します。最低限、ドメイン名、Route 53 Hosted Zone ID、private subnet の CIDR を指定してください。

```hcl
aws_region  = "ap-northeast-1"
name_prefix = "lab"
env         = "dev"

domain_name     = "example.com"
route53_zone_id = "Z1234567890ABC"

private_subnet_cidrs = {
  a = "10.0.11.0/24"
  d = "10.0.12.0/24"
}

# ACM 証明書が ISSUED になってから true に変更する
enable_https_listener = false

# 検証環境以外では必ずアクセス元を絞り込む
alb_ingress_cidrs = ["0.0.0.0/0"]

# 空配列のままなら SSH は無効。必要な場合は管理元 CIDR を指定する
ssh_ingress_cidrs = []

tags = {
  Project = "alb-asg-https"
}
```

認証情報、秘密鍵などの機密情報を `terraform.tfvars` に記載・コミットしないでください。

## デプロイ手順

ACM 証明書は DNS 検証の完了後でなければ ALB リスナーへ関連付けられないため、HTTPS は意図的に 2 段階で有効化します。

1. 初期化、整形確認、検証、最初の実行計画の確認を行います。

   ```bash
   terraform init
   terraform fmt -check -recursive
   terraform validate
   terraform plan
   ```

2. `enable_https_listener = false` のまま、確認済みの計画をユーザー自身で適用します。network、ALB、ASG、ACM 証明書、DNS 検証レコード、Route 53 Alias、WAF が作成されます。

   ```bash
   terraform apply
   ```

3. ACM 証明書が `ISSUED` になるまで待ちます。AWS コンソールまたは AWS CLI で証明書を確認できます。

   ```bash
   aws acm list-certificates \
     --region ap-northeast-1 \
     --query 'CertificateSummaryList[*].[DomainName,CertificateArn]' \
     --output table
   ```

4. `enable_https_listener` を `true` に変更し、計画を確認したうえでユーザー自身で適用します。

   ```bash
   terraform plan
   terraform apply
   ```

HTTPS が無効な間、ポート 80 は ALB が固定の `200` レスポンスを返します。この状態では target group へ転送されません。HTTPS を有効化すると、ポート 80 は 443 へリダイレクトし、HTTPS リスナーが nginx インスタンスへ転送します。

## 動作確認

HTTPS 有効化と DNS 伝播の完了後に実行します。

```bash
curl -I http://example.com
# HTTP/1.1 301 Moved Permanently

curl -I https://example.com
# HTTP/2 200
```

ALB の DNS 名、ASG 名、VPC ID、subnet ID、target group ARN、Web 用 security group ID も出力できます。

```bash
terraform output
```

## 主要な入力変数

| 名前 | 既定値 | 説明 |
| --- | --- | --- |
| `aws_region` | `ap-northeast-1` | リソースを作成する AWS リージョン |
| `name_prefix` / `env` | `lab` / `dev` | 結合してリソース名のベースとして使用 |
| `domain_name` | 必須 | ACM 証明書と Route 53 Alias に使用する FQDN |
| `route53_zone_id` | 必須 | `domain_name` を管理する Hosted Zone ID |
| `enable_https_listener` | `false` | HTTPS リスナーを作成し、HTTP から HTTPS へのリダイレクトを有効化 |
| `alb_ingress_cidrs` | `0.0.0.0/0` | ALB へのアクセスを許可する CIDR |
| `ssh_ingress_cidrs` | `[]` | Web インスタンスへの SSH を許可する任意の CIDR |
| `instance_type` | `t3.micro` | ASG が使用する EC2 インスタンスタイプ |
| `asg_min_size` / `asg_desired_capacity` / `asg_max_size` | `2` / `2` / `4` | ASG の最小・初期・最大台数 |
| `req_per_target` | `100` | スケーリングに使用するターゲットあたりリクエスト数の閾値 |

すべての入力変数は [variables.tf](variables.tf) を参照してください。

## セキュリティ上のポイント

- Web インスタンスには public IP を付与せず、インターネット公開は ALB のみに限定します。
- ALB のポート 443 は、HTTPS リスナー有効時だけ開放します。
- Web 用 security group は、ALB 用 security group からのポート 80 だけを許可します。
- `ssh_ingress_cidrs` を明示設定しない限り SSH は閉じています。運用時は AWS Systems Manager Session Manager の利用を推奨します。
- WAF には AWS Managed Common Rule Set と Known Bad Inputs Rule Set を適用します。
- ACM 検証レコードとドメインの A Alias は、指定した Route 53 Hosted Zone に書き込まれます。適用前に Zone ID を必ず確認してください。

## コストと削除

この構成では、NAT Gateway 1 台と EC2 2 台以上が常時稼働するほか、ALB と WAF の料金が発生します。長期間利用する前に AWS Pricing Calculator で見積もってください。

環境が不要になったら、まず削除計画を確認してから、ユーザー自身で実行してください。

```bash
terraform plan -destroy
terraform destroy
```

この構成が管理する ALB、ASG、NAT Gateway、WAF の関連付け、ACM 証明書、Route 53 レコードが削除されます。削除前に、対象ドメインと Hosted Zone が正しいことを確認してください。
