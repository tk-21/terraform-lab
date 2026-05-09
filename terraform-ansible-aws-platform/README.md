# terraform-ansible-aws-platform

Terraform × Ansible × AWS で、2AZ 構成の Web 基盤をハンズオン形式で構築するプロジェクトです。  
`Terraform` で AWS インフラを作り、`Ansible` で App EC2 に `Nginx + Gunicorn + Flask` を配備し、`GitHub Actions + OIDC` で Terraform の CI/CD を構成します。

アーキテクチャ全体は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。  
この README では、実際にハンズオンを進めるための手順を、初回セットアップから動作確認、クリーンアップまで順番にまとめています。

## このハンズオンで得られること

- Terraform で VPC、EC2、ALB、IAM、CloudWatch をモジュール分割して構築する力
- Ansible で EC2 のミドルウェア設定とアプリ配備を自動化する力
- `Terraform` と `Ansible` の責務分離を実践的に理解する力
- `SSM Session Manager` を使って、SSH 鍵に依存しない安全な運用パターンを学ぶ機会
- `IMDSv2`、最小権限 SG、OIDC などを含む AWS セキュリティベストプラクティスの理解
- `GitHub Actions + OIDC` で IAM アクセスキーを使わない CI/CD を構成する経験
- `CloudWatch Agent`、Dashboard、Alarm、SNS を使った監視の基本実装
- ポートフォリオとして説明しやすい、実務寄りの IaC 構成を一通り作り切る経験

## このハンズオンで作るもの

- 3-tier VPC
- Public subnet 上の ALB
- Private subnet 上の App EC2 2台
- Public subnet 上の Bastion EC2 1台
- SSH を使わない SSM ベースの運用経路
- Nginx 経由で公開される Flask API
- CloudWatch Agent / Dashboard / Alarm / SNS 監視
- GitHub Actions OIDC による Terraform 自動実行

## 完成イメージ

```text
Internet
  -> ALB
    -> App EC2 x 2 (private subnet)
      -> Nginx
        -> Gunicorn
          -> Flask

Operator
  -> Ansible
    -> AWS Systems Manager
      -> App EC2

GitHub Actions
  -> OIDC
    -> Terraform plan/apply
```

## 前提条件

この README は、Linux / macOS のターミナルから作業する前提です。

必要なもの:

- AWS アカウント
- GitHub アカウント
- `aws` CLI
- `terraform` 1.6 以上
- `python3`
- `git`

あると便利なもの:

- `jq`
- `session-manager-plugin`

バージョン確認:

```bash
aws --version
terraform version
python3 --version
git --version
```

## 事前に理解しておくこと

- Terraform の `apply` / `destroy` は実際に AWS リソースを作成・削除します
- App EC2 は private subnet にあるため、SSH ではなく `SSM Session Manager` で入ります
- `NAT Gateway` と `ALB` が比較的コストのかかる構成です
- Terraform の state は `S3 + DynamoDB` で管理します

## リポジトリ構成

```text
.
├── README.md
├── ARCHITECTURE.md
├── CLAUDE.md
├── phase1.md
├── phase2.md
├── phase3.md
├── phase4.md
├── phase5.md
├── terraform/
├── ansible/
└── app/
```

補助ドキュメント:

- `phase1.md` - backend と VPC
- `phase2.md` - EC2 / ALB / IAM / Bastion
- `phase3.md` - Ansible / Nginx / Flask
- `phase4.md` - GitHub Actions / OIDC
- `phase5.md` - CloudWatch / Alarm / Dashboard

## 1. 作業ディレクトリへ移動

```bash
cd /path/to/terraform-ansible-aws-platform
pwd
```

## 2. Python 仮想環境を作成

このプロジェクトでは、Python を使う作業は `.venv` で行います。

```bash
python3 -m venv .venv
source .venv/bin/activate
which python
```

`which python` が `.venv/bin/python` を指していれば OK です。

Ansible 実行に必要なパッケージを入れます。

```bash
pip install --upgrade pip
pip install ansible boto3 botocore
```

Ansible Collection を入れます。

```bash
ansible-galaxy collection install -r ansible/requirements.yml
```

## 3. AWS 認証を確認

AWS CLI が正しく使えることを確認します。

```bash
aws sts get-caller-identity
aws configure list
```

想定リージョンは `ap-northeast-1` です。必要なら明示設定します。

```bash
aws configure set region ap-northeast-1
```

## 4. Terraform backend 用リソースを作成

まずは Terraform state を置くための S3 バケットと、state lock 用の DynamoDB を作ります。

作業ディレクトリ移動:

```bash
cd terraform/bootstrap
```

初期化:

```bash
terraform init
terraform validate
terraform fmt -recursive
```

実行計画の確認:

```bash
terraform plan -out=tfplan
```

内容に問題がなければ apply:

```bash
terraform apply tfplan
```

出力例として、以下が得られます。

- `state_bucket_name`
- `lock_table_name`

## 5. backend.tf の bucket 名を自分の AWS アカウントに合わせる

`terraform/backend.tf` の bucket 名はプレースホルダーになっています。

```hcl
bucket = "tap-terraform-state-YOUR_ACCOUNT_ID"
```

まず AWS アカウント ID を確認:

```bash
aws sts get-caller-identity --query Account --output text
```

その値を使って `terraform/backend.tf` を次のように更新します。

```hcl
bucket = "tap-terraform-state-123456789012"
```

## 6. 本体インフラを作成

次に `dev` 環境のインフラを作成します。

```bash
cd ../environments/dev
```

初期化と整形:

```bash
terraform init
terraform validate
terraform fmt -recursive
```

実行計画:

```bash
terraform plan -out=tfplan
```

ここで作成される主なリソース:

- VPC
- Public / Private / DB subnet
- Internet Gateway
- NAT Gateway
- Security Groups
- App EC2 2台
- Bastion EC2 1台
- ALB
- CloudWatch 関連
- GitHub Actions OIDC 用 IAM Role

内容に問題がなければ apply:

```bash
terraform apply tfplan
```

## 7. Terraform 出力を確認

```bash
terraform output
```

特に確認したい出力:

```bash
terraform output alb_dns_name
terraform output app_instance_ids
terraform output bastion_instance_id
terraform output github_actions_role_arn
terraform output cloudwatch_dashboard_name
```

## 8. インフラ構築後の確認

### VPC と Subnet

```bash
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=terraform-ansible-platform"
aws ec2 describe-subnets --filters "Name=tag:Project,Values=terraform-ansible-platform"
```

### EC2

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=terraform-ansible-platform" \
            "Name=instance-state-name,Values=running"
```

見たいポイント:

- App EC2 が 2台
- Bastion EC2 が 1台
- App EC2 に public IP が付いていない

### ALB

```bash
terraform output -raw alb_dns_name
```

この時点では、まだ Ansible 未実行ならターゲットは `unhealthy` でも正常です。

## 9. SSM 接続を確認

App EC2 の instance ID を取得:

```bash
terraform output app_instance_ids
```

1台選んで SSM セッション開始:

```bash
aws ssm start-session --target <app_instance_id>
```

セッションに入れたら、以下を確認します。

```bash
uname -a
systemctl status amazon-ssm-agent
```

IMDSv2 強制確認:

```bash
curl http://169.254.169.254/latest/meta-data/
```

これは失敗する想定です。  
次に IMDSv2 トークンを使います。

```bash
TOKEN=$(curl -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

curl -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id
```

こちらは成功すれば OK です。

## 10. Ansible Dynamic Inventory を確認

リポジトリルートに戻ります。

```bash
cd ../../..
```

Ansible ディレクトリへ移動:

```bash
cd ansible
```

Dynamic Inventory 一覧表示:

```bash
ansible-inventory -i inventory/aws_ec2.yml --list
```

見たいポイント:

- `role_app` グループが存在する
- App EC2 2台が列挙される

見やすく確認する例:

```bash
ansible-inventory -i inventory/aws_ec2.yml --list | jq '.role_app'
```

## 11. Ansible で App サーバーを構成

まず dry-run:

```bash
ansible-playbook site.yml --check --diff
```

問題なければ本実行:

```bash
ansible-playbook site.yml
```

この Playbook で行われること:

- `common` で OS 基本設定
- `nginx` でリバースプロキシ設定
- `flask_app` で Flask アプリを配備
- `cloudwatch_agent` で CloudWatch Agent を設定

## 12. Ansible 実行後の確認

### ALB ヘルスチェック

しばらく待ってから、ALB DNS にアクセスします。

```bash
ALB_DNS=$(cd ../terraform/environments/dev && terraform output -raw alb_dns_name)
echo "$ALB_DNS"
curl "http://$ALB_DNS/api/health"
```

期待結果:

- HTTP 200
- `{"status":"healthy", ...}` が返る

### アプリ情報 API

```bash
curl "http://$ALB_DNS/api/info"
```

確認ポイント:

- `instance_id`
- `availability_zone`
- `instance_type`
- `local_ipv4`

複数回叩くと、ALB 配下の別インスタンスに分散されることがあります。

### Playbook の冪等性確認

再度実行します。

```bash
ansible-playbook site.yml
```

理想的には、大半のタスクが `ok` で進み、不要な差分が出ない状態です。

## 13. CloudWatch を確認

Terraform 出力からダッシュボード名を確認:

```bash
cd ../terraform/environments/dev
terraform output cloudwatch_dashboard_name
terraform output cloudwatch_sns_topic_arn
terraform output cloudwatch_ssm_parameter_name
```

AWS コンソールで確認したいもの:

- CloudWatch Dashboard
- `/tap/dev/nginx/access`
- `/tap/dev/nginx/error`
- `/tap/dev/flask-app`
- SNS メールサブスクリプション

SNS はメール確認リンクを開いて Confirm する必要があります。

## 14. GitHub Actions OIDC を設定

Terraform で作成された GitHub Actions Role ARN を取得:

```bash
terraform output -raw github_actions_role_arn
```

GitHub リポジトリの `Settings -> Secrets and variables -> Actions` に以下を追加します。

| Secret 名 | 値 |
|---|---|
| `AWS_ROLE_ARN` | `terraform output -raw github_actions_role_arn` の結果 |
| `AWS_REGION` | `ap-northeast-1` |

## 15. GitHub Actions 動作確認

Terraform 配下に変更を入れて PR を作成すると、`terraform-plan.yml` が動きます。

確認ポイント:

- `terraform fmt -check`
- `terraform init`
- `terraform validate`
- `terraform plan`
- PR に plan 結果がコメントされる

その後 `main` にマージすると、`terraform-apply.yml` が動きます。

確認ポイント:

- OIDC で AWS 認証している
- apply が完了する
- Job summary に ALB DNS が表示される

## 16. ハンズオンの推奨進行順

この README だけでも進められますが、学習目的なら次の順で読むのがおすすめです。

1. `README.md` で全体の流れを掴む
2. `ARCHITECTURE.md` で構成を理解する
3. `phase1.md` から `phase5.md` を順に読みながら進める

## 17. よくあるつまずきポイント

### `terraform init` が backend 関連で失敗する

- `terraform/backend.tf` の bucket 名が実アカウント ID に更新されているか確認
- 先に `terraform/bootstrap` を apply しているか確認

### `aws ssm start-session` が失敗する

- 対象 EC2 が `running` か確認
- `AmazonSSMManagedInstanceCore` が EC2 Role に付いているか確認
- ローカルに `session-manager-plugin` が入っているか確認

### `ansible-inventory` でホストが出ない

- EC2 タグ `Project=terraform-ansible-platform`
- EC2 タグ `Environment=dev`
- EC2 タグ `Role=app`
- App EC2 が `running`

### `curl http://<ALB_DNS>/api/health` が 200 にならない

- `ansible-playbook site.yml` が正常終了したか
- `systemctl status nginx`
- `systemctl status flask-app`
- ALB Target Group が healthy か

## 18. コスト注意

概算では月額 `$40` 台になる可能性があります。特にコスト影響が大きいのは以下です。

- ALB
- NAT Gateway
- EC2 3台

検証が終わったら早めに削除するのがおすすめです。

## 19. クリーンアップ

削除は依存関係の逆順で行います。

まず本体インフラ:

```bash
cd terraform/environments/dev
terraform destroy
```

その後 backend:

```bash
cd ../../bootstrap
terraform destroy
```

削除後に確認したいもの:

- EC2 が消えている
- ALB が消えている
- NAT Gateway が消えている
- S3 backend bucket が削除されている
- DynamoDB lock table が削除されている

## 20. 次の改善候補

- ACM 証明書を使った HTTPS 化
- Auto Scaling Group 化
- `stg` / `prod` 環境追加
- RDS 追加で完全 3-tier 化
- VPC Endpoint 導入で NAT コスト削減
- IAM 権限のさらなる最小化

## 21. 参考ドキュメント

- [ARCHITECTURE.md](./ARCHITECTURE.md)
- [CLAUDE.md](./CLAUDE.md)
- [phase1.md](./phase1.md)
- [phase2.md](./phase2.md)
- [phase3.md](./phase3.md)
- [phase4.md](./phase4.md)
- [phase5.md](./phase5.md)
