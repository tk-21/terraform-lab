# Terraform AWS Sandbox Architecture
https://chatgpt.com/g/g-p-690ea2b2c5948191a108d07e18727e7f-terraform/c/69512204-eb8c-8322-91f0-7f669735e447

## 概要

本ディレクトリは、Terraform を用いて
**実務で頻出する AWS 構成（ALB + ASG + HTTPS + WAF）** を
**安全に段階構築できる Sandbox 環境**です。

* 学習・検証・PoC 用途
* 本番相当の設計（private subnet / NAT / HTTPS / AutoScaling）
* 破棄前提（terraform destroy 可）

---

## 構成概要

```
Internet
  ↓
Application Load Balancer (Public Subnet)
  ├─ HTTP : 80
  │    └─ HTTPS へリダイレクト
  └─ HTTPS : 443 (ACM 証明書)
        ↓
Target Group
        ↓
Auto Scaling Group (Private Subnet)
  └─ EC2 (Amazon Linux 2023 + nginx)
        ↑
        └─ NAT Gateway / S3 VPC Endpoint
```

### 特徴

* EC2 は **private subnet** に配置
* インターネット公開点は **ALB のみ**
* ASG により EC2 台数は自動増減
* HTTPS は **証明書発行後に有効化**
* WAF を ALB に直接関連付け

---

## ディレクトリ構成

```text
terraform-lab/
├── modules/
│   ├── network/     # VPC / Subnet / NAT / VPC Endpoint
│   ├── alb/         # ALB / SG / Listener / TargetGroup
│   ├── asg_web/     # LaunchTemplate / ASG / ScalingPolicy
│   ├── acm_r53/     # ACM + Route53 DNS validation
│   └── waf_alb/     # WAFv2 (Managed Rules)
└── envs/
    └── sandbox/     # 本README対象ディレクトリ
```

---

## 前提条件

* Terraform >= 1.5
* AWS CLI 設定済み
* Route53 Hosted Zone 作成済み（ドメイン取得済み）

```bash
aws configure
aws sts get-caller-identity
```

---

## 変数ファイル（terraform.tfvars）

例：

```hcl
aws_region = "ap-northeast-1"

name_prefix = "lab"
env         = "sandbox"

vpc_cidr = "10.0.0.0/16"

public_subnet_cidrs = {
  a = "10.0.1.0/24"
  c = "10.0.2.0/24"
}

private_subnet_cidrs = {
  a = "10.0.11.0/24"
  d = "10.0.12.0/24"
}

alb_ingress_cidrs = ["0.0.0.0/0"]
ssh_ingress_cidrs = []

domain_name      = "example.com"
route53_zone_id  = "ZXXXXXXXXXXXXX"

enable_https_listener = false

instance_type        = "t3.micro"
asg_min_size         = 2
asg_desired_capacity = 2
asg_max_size         = 4
req_per_target       = 100

tags = {
  ManagedBy = "terraform"
}
```

---

## デプロイ手順（重要）

### ① 初期化

```bash
cd terraform-lab/alb-asg-https
terraform init
```

---

### ② HTTP 構成で apply（HTTPS 無効）

```bash
terraform apply
```

この段階で作成されるもの：

* VPC / Subnets / NAT
* ALB (HTTP only)
* ASG / EC2
* ACM 証明書（DNS validation 中）

---

### ③ ACM 証明書の発行を確認

```bash
aws acm list-certificates \
  --region ap-northeast-1 \
  --query "CertificateSummaryList[*].[DomainName,CertificateArn]" \
  --output table
```

Route53 の検証が完了するとステータスが `ISSUED` になります。

---

### ④ HTTPS を有効化

`terraform.tfvars` を修正：

```hcl
enable_https_listener = true
```

再 apply：

```bash
terraform apply
```

この段階で：

* HTTP → HTTPS リダイレクト有効
* HTTPS(443) リスナー作成
* 証明書が ALB に関連付けられる

---

## 動作確認

```bash
curl -I http://example.com
# → 301 HTTPS

curl -I https://example.com
# → 200 OK
```

ブラウザでもアクセス可能。

---

## Auto Scaling 動作

* CPU 50% 超過 → スケールアウト
* ALB RequestCount/Target 超過 → スケールアウト
* 負荷減少時は自動スケールイン

---

## 削除（注意）

```bash
terraform destroy
```

※ ACM / Route53 / ALB / NAT すべて削除されます。

---

## 設計上のポイント

* HTTPS を **同一 apply で強制しない**
* module 間は output → input で依存管理
* enable_https_listener による **安全スイッチ**
* private subnet + NAT + VPC Endpoint の実務構成

---

## 想定用途

* Terraform 学習
* AWS 構成テンプレ作成
* 本番前 PoC
* ASG / ALB / HTTPS の動作理解

---

## 次の発展案

* CloudFront 追加
* ACM(us-east-1) 対応
* Spot Instance 混在
* Blue/Green デプロイ
* envs/stg / envs/prod 展開

---




了解。いまの `terraform plan` から読み取れる **“あなたの構成が何を作るのか”** を、初心者向けに噛み砕いて説明します（ただし内容は実務そのものです）。

---

## 全体像（何を作っている？）

あなたの Terraform は、AWS でよくある **「Web公開の基本セット」** を作ります。

* **VPC（ネットワークの器）**
* **public / private サブネット（外に出す場所 / 内側の場所）**
* **NAT（private から外に出るための出口）**
* **ALB（ロードバランサ）**
* **ASG（EC2台数を自動で2〜4に増減）**
* **ACM（HTTPS証明書）＋ Route53（DNS）**
* **WAF（Web攻撃対策）**
* （＋S3 VPC Endpoint：S3へ行く通信をAWS内に閉じる）

しかもこれを **module（部品）** に分けて再利用できる形にしています。

---

## module ごとの役割（どこで何をしてる？）

### 1) `module.network`（ネットワーク担当）

「AWSの土地と道路」を作る部品です。

作るもの：

* **VPC**：10.0.0.0/16 の大きなネットワーク
* **Public Subnet（a/c）**：ALBやNATを置く、外から来られる場所
* **Private Subnet（a/d）**：ASG（EC2）を置く、外から直接入れない場所
* **Internet Gateway**：VPCをインターネットにつなぐ門
* **NAT Gateway + EIP**：private subnet のサーバが “外へ出る” ための出口
* **Route Table**：publicはIGWへ、privateはNATへ流すルール
* **S3 VPC Endpoint（Gateway）**：S3への通信をインターネット経由にしない（コスト/セキュリティ的に良い）

イメージ：

* public は「表通り」、private は「裏通り」
* private のサーバは外から来れないけど、NAT 経由で外へ出られる

---

### 2) `module.alb`（ALB + セキュリティグループ担当）

「入口（ロードバランサ）と、入口〜サーバの通行許可」を作る部品です。

作るもの：

* **ALB（インターネット向け）**
* **Target Group（ALBが流す先のグループ）**
* **Listener**

  * **HTTP 80 → HTTPS 443 にリダイレクト**
  * **HTTPS 443 → TargetGroup に forward**
* **Security Group 2つ**

  * `sg-alb`：外部から 80/443 を許可（alb_ingress_cidrs で制限可能）
  * `sg-web`：ALB からの 80 のみ許可（外部からの直アクセスを防ぐ）

ポイント：

* 「インターネット → ALB まではOK」
* 「ALB → EC2 の 80 だけOK」
* EC2へ直接 80/443 は行けない（SGで遮断）

---

### 3) `module.asg_web`（EC2を増減させる担当）

「Webサーバ群（EC2）をまとめて運用する」部品です。

作るもの：

* **Launch Template**：EC2の設計図（AMI, instance_type, user_data など）
* **Auto Scaling Group（ASG）**

  * min=2 / desired=2 / max=4
  * サブネットは private 側（想定）
* **AutoScaling Policy**

  * **CPU 50% 目標**で自動増減（TargetTracking）
  * **ALB RequestCountPerTarget** を見て増減（例：1台あたり100req目標）

ユーザーが感じる効果：

* 最初は EC2 が 2台
* 負荷が増えると 3台→4台
* 落ち着くと減る（設定次第）

---

### 4) `module.acm_r53`（HTTPS証明書とDNS担当）

「[https://ecssafp.jp](https://ecssafp.jp) を成立させる」部品です。

作るもの：

* **ACM Certificate（DNS検証）**
* **Route53 の検証用CNAMEレコード**（acm_validation）
* **Certificate Validation（発行完了を待つ）**
* **Route53 A(ALIAS) レコード**

  * `ecssafp.jp` → ALB に向ける

初心者がつまずきやすいポイント：

* apply 中に **証明書の発行待ち** が発生しがち（DNS反映のタイムラグ）
* それが `aws_acm_certificate_validation.this: Still creating...` の正体

---

### 5) `module.waf_alb`（WAF担当）

「ALBの前にセキュリティフィルタを付ける」部品です。

作るもの：

* **WAFv2 WebACL（REGIONAL）**
* **AWS Managed Rules**

  * CommonRuleSet
  * KnownBadInputs
* **ALB への関連付け（association）**

効果：

* よくある攻撃パターン（怪しい入力・既知の悪いリクエスト）を自動でブロック/検知

---

## トラフィックの流れ（超重要）

ユーザーがブラウザでアクセスすると、こう流れます：

1. ユーザー → **Route53**（DNSで ALB を引く）
2. ユーザー → **ALB**
3. 80 で来たら → **443へリダイレクト**
4. 443 で来たら → **ACM証明書でHTTPS終端**
5. ALB → **Target Group → ASGのEC2へ転送**
6. EC2 は private subnet にいるので **直接インターネットから到達できない**

---

## いまの `plan` が示していること

`Plan: 33 to add, 0 to change, 0 to destroy.`

これは「今 state が空（destroy済み）だから、全部新規作成」という意味です。
差分が “0 change / 0 destroy” なのは健全。

---

## 初心者が理解すると一気に伸びる「設計の狙い」

この構成の狙いは3つです。

1. **公開点を ALB に集約**（EC2を直接さらさない）
2. **EC2 は ASG で使い捨て**（壊れても増減してもOK）
3. **HTTPS/WAF/DNS をIaC化**（手作業を排除）

ここまでできているなら、かなり実務に近いです。

---

## 次に「初心者が伸びる」チェック項目（短く）

apply 後に確認してみてください：

* `https://ecssafp.jp` にアクセスして nginx ページが出るか
* ALB のターゲットヘルスが `healthy` か
* ASG のインスタンスが 2台になっているか
* WAF の metrics が CloudWatch に出ているか（サンプルでもOK）

---

必要なら、あなたのディレクトリ構成（envs/dev の main.tf と modules の一覧）に合わせて、**「どのファイルが何を担当してるか」**も図で説明します。


  
# terraformのロジックも解説してほしい。


了解。いまの構成を「Terraformのロジック（なぜそう書くのか／どう評価されるのか）」込みで、初心者向けに整理します。
※あなたの `plan` に出ている module 構成（network / alb / asg_web / acm_r53 / waf_alb）を前提に説明します。

---

## 1) Terraform の基本ロジック（超重要）

Terraform は大きく言うと、毎回これをやってます。

1. **設定（*.tf）を読む**
2. **依存関係をグラフ化**（AがないとB作れない、を自動推定）
3. **現実（AWS）と state を比較**して差分を計算（plan）
4. **差分どおりに作成/更新/削除**（apply）

あなたの状態は `destroy 済みで state が空` なので、plan が全部 `+ create` になっています。

---

## 2) “参照したら依存関係になる” というルール

Terraform は、**参照（aws_vpc.this.id など）を見て自動で順序を決めます**。

例（network module 内）：

* `aws_subnet.public` が `vpc_id = aws_vpc.this.id` を参照
  → **VPC が先、Subnet が後**になる

例（acm_r53 module）：

* `aws_acm_certificate_validation.this` が
  `validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]` を参照
  → **Route53 record ができてから validation を待つ**になる

「depends_on」を乱用しなくても動くのは、この仕組みのおかげです。

---

## 3) module のロジック（部品化の考え方）

module は「複数リソースのまとまり」を **入力（variables）→ 出力（outputs）** にしたものです。

* `envs/dev/main.tf` は **配線（wiring）** をするだけ
* 実体は `modules/*` の中にある

### 代表例：HTTPS の配線

* `module.acm_r53` が `certificate_arn` を output
* `module.alb` が `certificate_arn` を input にして HTTPS listener を作る

つまり **「ACM module が証明書を作る → ALB module がそれを使う」** をコードで配線している。

---

## 4) “for_each / map” のロジック（AZ分散）

あなたは CIDR を `map(string)` で持って、`for_each` でサブネットを作っています。

```hcl
variable "public_subnet_cidrs" {
  type = map(string)
  # { a = "10.0.1.0/24", c = "10.0.2.0/24" }
}

resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}" # ap-northeast-1a など
}
```

### ここでのTerraformのロジック

* `for_each` は **キー（a/c/d）でリソースを識別**します
* state 上のアドレスはこうなる：

  * `aws_subnet.public["a"]`
  * `aws_subnet.public["c"]`

だから、`a/c` を `a/d` に変えると…

* `["c"]` が消える → **destroy**
* `["d"]` が増える → **create**
  になる（差分読みの練習課題の本質）

> `count` より `for_each(map)` の方が “変更に強い” のは、キーが固定のためです。

---

## 5) locals のロジック（計算用の変数）

`locals` は「式の結果を名前にして再利用」するための仕組みです。
AWSには何も作りません。**Terraform内の計算だけ**です。

例：

* `base_name = "${var.name_prefix}-${var.env}"`
  → どのリソース名にも同じprefixが付く

例：

* “public subnet を2つだけ選ぶ”

  ```hcl
  public_subnet_keys_2 = slice(sort(keys(aws_subnet.public)), 0, 2)
  ```

  → サブネットが a/c/d みたいに増えても **先頭2つを安定的に選ぶ**ためのロジック

---

## 6) data ソースのロジック（読み取り専用）

`data` は **AWSから情報を取得するだけ**です（作成はしない）。

例：

```hcl
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter { name="name" values=["al2023-ami-*-x86_64"] }
}
```

Terraform は plan 時にこれを読んで、

* `image_id = data.aws_ami.al2023.id`
  として Launch Template に埋め込みます。

あなたの plan 冒頭に
`data.aws_ami.al2023: Read complete ...`
が出ているのは、この “読み取り” が走っている証拠。

---

## 7) “known after apply” のロジック（apply 後に確定する値）

plan に `known after apply` が多いのは正常です。

理由は、

* AWSが作成後にしか返さない値（ARN, DNS名, Zone ID など）があるから。

例：

* ALB の `dns_name` は作った後に決まる
* ACM の `domain_validation_options` は作った後に決まる
  → そこから Route53 CNAME を作る
  → validation が終わってから HTTPS listener が安定する

Terraformはこの依存を理解しているので、順番が成立します。

---

## 8) state のロジック（なぜ state が重要か）

state は「Terraformが覚えている現実のメモ」です。

* state がある → 変更差分が出る
* state が空（destroy後） → “初回構築” になる

あなたが `terraform state list` で空だったのは、まさにその状態。

---

## 9) “module化で起きたエラー” の正体（学びポイント）

あなたが途中で遭遇したやつは全部、Terraformのルールが原因です。

* **Duplicate variable / local**
  → module内（またはroot内）で同じ名前を2回書けない
* **Reference to undeclared resource**
  → 参照先を module 化で移動したのに、古い tf が残っていて参照していた
* **Module not installed**
  → module 追加したら init 必須
* **Variables not allowed**
  → `${NAME}` を HCL の “変数展開” と誤認識させた（文字列置換や templatefile にする必要あり）

この辺を経験した時点で、Terraformの“事故ポイント”は一周してます。

---

## 10) 次に伸びる「Terraformロジック練習」3本（すぐ効く）

### A) 差分読み（replace / destroy / update を見抜く）

* `public_subnet_cidrs` を `a/c → a/d` に変えて `plan` を読む
  → 何が destroy/create になる？

### B) 参照の移し替え（root→module化の必修）

* root で参照してる `aws_*` を全部 `module.xxx.*` に置換して validate を通す

### C) plan の固定（実務の事故防止）

```bash
terraform plan -out tfplan
terraform show -no-color tfplan | less
terraform apply tfplan
```

---

## ここからの提案（次の一手）

「Terraformのロジックが分かった」次に一番効くのは、

* **SSM化（SSHレス）**
* **ASG を private subnet に完全寄せる（今の方向性）**
* **VPC Endpoint（ssm/ec2messages/ssmmessages）追加で NAT依存を外す**

この3点です。

---

もしよければ、あなたの `envs/dev/main.tf`（module呼び出し部分）だけ貼ってください。
それを元に **「この1行が何を配線しているか」** を行単位で解説します（初心者が一気に腹落ちします）。
