# secure-3tier-iac-pipeline

Terraform と Ansible を使って、AWS 上にセキュアな 3 層 Web アプリ基盤を構築するハンズオン用プロジェクトです。

この README は、はじめてこのリポジトリを触る人が「何を準備して、どの順番で実行すればよいか」を迷わず進められるように、実行手順をハンズオン形式でまとめています。

## このハンズオンで得られること

- Terraform で本番を意識した AWS 3 層構成をコード化する流れを体験できる
- ALB / EC2 / Aurora を分離した基本的な Web インフラ設計を理解できる
- KMS、Secrets Manager、SSM、VPC Endpoint などを使った実践的なセキュリティ設計を学べる
- Ansible による OS ハードニングとアプリデプロイの自動化を体験できる
- `plan`、`apply`、動作確認、ドリフト検出まで含めた IaC 運用の一連の流れをつかめる

## このハンズオンで作るもの

- パブリックサブネット: ALB
- プライベートサブネット: EC2 Auto Scaling Group
- データサブネット: Aurora MySQL Serverless v2
- 周辺セキュリティ: IAM, KMS, Secrets Manager, SSM Session Manager, VPC Endpoint, CloudWatch Logs
- 構成管理: Ansible による OS ハードニングとアプリデプロイ

構成の詳細は [ARCHITECTURE.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ARCHITECTURE.md) を参照してください。

## 進め方の全体像

1. ローカル環境と AWS 認証を準備する
2. `.venv` を有効化して作業環境をそろえる
3. `bootstrap.sh` で tfstate 用 S3 / DynamoDB を作る
4. `backend.tf` と `terraform.tfvars` を設定する
5. `terraform init` と `terraform plan` で内容を確認する
6. `terraform apply` はユーザー自身が実行する
7. Ansible の変数と Vault を設定する
8. Ansible でハードニングとアプリデプロイを行う
9. ALB / SSM / Drift Check で動作確認する

## 前提条件

- OS: macOS または Linux
- AWS CLI v2 がインストール済み
- Terraform `>= 1.7.0`
- Python 3 と `venv` が利用可能
- Ansible が利用可能
- AWS 認証済み
- AWS 上で以下を作成できる権限がある
  - VPC / Subnet / NAT Gateway / VPC Endpoint
  - EC2 / ALB / Auto Scaling
  - RDS Aurora
  - IAM / KMS / Secrets Manager / SSM
  - S3 / DynamoDB / CloudWatch Logs

## 0. 作業開始前チェック

このプロジェクトでは、Python を使う作業は必ず `.venv` で行います。

```bash
cd /home/takuya/terraform-lab/secure-3tier-iac-pipeline
pwd
ls -d .venv
source .venv/bin/activate
which python
```

期待値:

- `pwd` がこのリポジトリのルートになっている
- `.venv` が存在する
- `which python` が `.venv/bin/python` を指している

まだ `.venv` がない場合は作成します。

```bash
python3 -m venv .venv
source .venv/bin/activate
```

注記:

- 現在のリポジトリ直下には `requirements.txt` がありません
- 必要に応じて、利用するツール群に合わせて追加してください

## 1. AWS 認証を確認する

まず AWS に正しく接続できるか確認します。

```bash
aws sts get-caller-identity
aws configure list
```

SSO を使っている場合は必要に応じてログインします。

```bash
aws sso login
```

リージョンは `ap-northeast-1` を前提にしています。

## 2. Terraform / Ansible のバージョンを確認する

```bash
terraform version
ansible --version
```

Terraform は `1.7.0` 以上であることを確認してください。

## 3. tfstate バックエンドを初期化する

最初に一度だけ、Terraform の state 保存先を作成します。

```bash
bash scripts/bootstrap.sh
```

このスクリプトは以下を作成します。

- S3 バケット: `s3t-prod-tfstate-{AWS_ACCOUNT_ID}`
- DynamoDB テーブル: `s3t-prod-tfstate-lock`

実行後、出力された S3 バケット名をメモしてください。

## 4. `backend.tf` を更新する

[terraform/envs/prod/backend.tf](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/terraform/envs/prod/backend.tf) の `bucket` はコメントアウトされたままです。`bootstrap.sh` の結果に合わせて実値を設定してください。

設定例:

```hcl
terraform {
  backend "s3" {
    bucket         = "s3t-prod-tfstate-123456789012"
    key            = "prod/terraform.tfstate"
    region         = "ap-northeast-1"
    encrypt        = true
    dynamodb_table = "s3t-prod-tfstate-lock"
  }
}
```

## 5. `terraform.tfvars` を作成する

このリポジトリには `terraform/envs/prod/terraform.tfvars` がまだありません。新規作成して、少なくとも以下を設定します。

配置場所:

- `terraform/envs/prod/terraform.tfvars`

記入例:

```hcl
owner          = "your-name-or-team"
aws_account_id = "123456789012"
enable_https   = false

# HTTPS を有効にする場合だけ設定
acm_certificate_arn = ""
```

補足:

- ハンズオンを HTTP のみで進める場合は `enable_https = false` のままで構いません
- HTTPS を使う場合は、`ap-northeast-1` に発行済みの ACM 証明書 ARN を指定してください

## 6. Terraform の初期化と確認を行う

`apply` の前に、必ず `init` と `plan` で内容を確認します。

```bash
cd terraform/envs/prod
terraform init
terraform fmt -recursive
terraform validate
terraform plan -var-file=terraform.tfvars
```

`backend.tf` を後から変更した場合は、必要に応じて再初期化します。

```bash
terraform init -reconfigure
```

## 7. Terraform Apply はユーザー自身が実行する

このプロジェクトでは、インフラ変更を伴うコマンドはユーザー自身が実行します。

実行候補:

```bash
cd terraform/envs/prod
terraform apply -var-file=terraform.tfvars
```

実行後に控えておくと便利な情報:

- `alb_dns_name`
- `aurora_cluster_endpoint`
- `session_logs_bucket_name`
- `ssm_connect_command`

確認コマンド:

```bash
terraform output
```

## 8. Ansible 用の変数を更新する

Terraform 構築後、Ansible 側の設定を合わせます。

### 8-1. AWS アカウント ID を更新する

[ansible/group_vars/all/vars.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vars.yml) の以下を実際の AWS アカウント ID に書き換えてください。

```yaml
aws_account_id: "123456789012"
```

この値は、SSM Session Manager のログバケット参照に使われます。

### 8-2. Vault 変数を確認する

[ansible/group_vars/all/vault.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vault.yml) には、Ansible Vault で扱う想定の値があります。

最低限確認したい項目:

- `vault_db_password`
- `vault_app_secret_key`
- `vault_chatwork_token`
- `chatwork_room_id`

まだ暗号化していない場合:

```bash
cd ansible
ansible-vault encrypt group_vars/all/vault.yml
```

編集するとき:

```bash
cd ansible
ansible-vault edit group_vars/all/vault.yml
```

## 9. 動的インベントリを確認する

EC2 が起動してから、Ansible が対象インスタンスを見つけられるか確認します。

```bash
cd ansible
ansible-inventory -i inventories/aws_ec2.yml --graph
```

期待値:

- `role_webserver` グループが表示される
- 配下に起動中の EC2 インスタンスが表示される

JSON 形式で詳しく見る場合:

```bash
ansible-inventory -i inventories/aws_ec2.yml --list
```

## 10. Ansible で OS ハードニングとアプリデプロイを実行する

Vault パスワードファイルを使う前提で、ラッパースクリプトから実行します。

```bash
export VAULT_PASSWORD_FILE=~/.vault_pass
bash scripts/run_ansible.sh site.yml
```

このプレイブックで実行される内容:

- `os_hardening`
- `app_deploy`

OS ハードニングだけ先に確認したい場合:

```bash
bash scripts/run_ansible.sh hardening.yml
```

## 11. 動作確認を行う

### 11-1. ALB 経由でアクセスする

Terraform 出力の `alb_dns_name` を使ってアクセスします。

```bash
cd terraform/envs/prod
terraform output alb_dns_name
```

ブラウザまたは `curl` で確認:

```bash
curl http://<alb_dns_name>/health
```

期待値:

- HTTP 200 が返る

### 11-2. SSM で EC2 に接続する

稼働中インスタンス ID を取得します。

```bash
aws ec2 describe-instances \
  --filters "Name=tag:Role,Values=webserver" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
```

接続:

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-1
```

### 11-3. Parameter Store を確認する

```bash
aws ssm get-parameter --name /ata-prod/app/db_endpoint --with-decryption --region ap-northeast-1
aws ssm get-parameter --name /ata-prod/app/db_reader_endpoint --with-decryption --region ap-northeast-1
```

### 11-4. Secrets Manager を確認する

```bash
aws secretsmanager get-secret-value \
  --secret-id ata-prod/rds/master-password \
  --region ap-northeast-1
```

## 12. ドリフトチェックを実行する

構成差分だけを確認したい場合は、変更を加えないチェックモードで実行できます。

```bash
export VAULT_PASSWORD_FILE=~/.vault_pass
bash scripts/run_drift_check.sh
```

このスクリプトは内部で以下を実行します。

```bash
ansible-playbook \
  -i inventories/aws_ec2.yml \
  --vault-password-file ~/.vault_pass \
  --check \
  --diff \
  drift_check.yml
```

## 13. よくあるハマりどころ

### `terraform init` で backend エラーが出る

- `backend.tf` の `bucket` が未設定
- `bootstrap.sh` を実行していない
- 変更後に `terraform init -reconfigure` をしていない

### `NoCredentialProviders` や認証エラーが出る

- `aws sts get-caller-identity` が成功するか確認する
- SSO 利用時は `aws sso login` を再実行する

### `ansible-inventory` でホストが 0 台になる

- `terraform apply` 後に EC2 が起動済みか確認する
- EC2 タグ `Project=secure-3tier-iac-pipeline` と `Environment=prod` が付いているか確認する
- [ansible/group_vars/all/vars.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vars.yml) の `aws_account_id` が置換済みか確認する

### `aws_ssm` 接続で失敗する

- 対象 EC2 が SSM Managed Instance になっているか確認する
- Session Manager 関連の VPC Endpoint と IAM 権限が正しく作成されているか確認する

### `/health` が失敗する

- ALB ターゲットグループでインスタンスが `healthy` になっているか確認する
- Ansible の `app_deploy` が正常終了しているか確認する

## 14. コスト注意

この構成は学習用途としてはかなり本格的です。特に以下のコストに注意してください。

- NAT Gateway が 3 台作成される
- Aurora Serverless v2 が起動する
- Interface VPC Endpoint が複数作成される
- ALB と CloudWatch Logs が継続課金される

長時間放置しないようにしてください。

## 15. 後片付け

インフラ削除もユーザー自身が実行してください。

実行候補:

```bash
cd terraform/envs/prod
terraform destroy -var-file=terraform.tfvars
```

削除後は以下も確認すると安心です。

- NAT Gateway が削除されたか
- Elastic IP が残っていないか
- S3 バケット内にオブジェクトが残っていないか

## 関連ドキュメント

- [ARCHITECTURE.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ARCHITECTURE.md)
- [terraform/envs/prod/README.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/terraform/envs/prod/README.md)
- [phase1.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/phase1.md)
- [phase2.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/phase2.md)
- [phase3.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/phase3.md)
- [phase4.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/phase4.md)
