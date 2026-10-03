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
4. `terraform.tfvars` を設定する（backend の bucket は `init` 時に渡す）
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

### 0-1. Ansible の依存パッケージを venv に入れる

Ansible は system 版(`/usr/bin/ansible*`)ではなく、必ず `.venv` 内のものを使います。
system 版は `/usr/bin/python3` で動くため、venv に入れた boto3 を参照できず、動的インベントリが失敗します。

```bash
source .venv/bin/activate
pip install ansible-core boto3 botocore
ansible-galaxy collection install -r ansible/requirements.yml
```

インストール後に確認します。

```bash
which ansible-inventory
python -c "import boto3, botocore; print(boto3.__version__)"
ansible-galaxy collection list | grep -E "amazon.aws|community.aws|ansible.posix"
```

期待値:

- `which ansible-inventory` が `.venv/bin/ansible-inventory` を指している
- boto3 のバージョンが表示される
- `amazon.aws`、`community.aws`、`ansible.posix` が一覧に出る

注記:

- 現在のリポジトリ直下には `requirements.txt` がありません。上記のインストール後に `pip freeze > requirements.txt` で、バージョンを pin して保存してください
- コレクションのバージョンも、`collection list` で確認して [ansible/requirements.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/requirements.yml) の `version:` に pin してください
- 動的インベントリの `amazon.aws.aws_ec2` は `amazon.aws` コレクション、SSM 接続(`aws_ssm`)は `community.aws` コレクションに含まれます
- `aws_ssm` 接続で実際に Playbook を動かすには、実行するマシンに Session Manager plugin(`session-manager-plugin`)も必要です

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

## 4. backend の bucket を確認する

[terraform/envs/prod/backend.tf](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/terraform/envs/prod/backend.tf) には `bucket` を書いていません。アカウント ID を含む値をコードに直書きしないため、`terraform init` 時に `-backend-config` で渡します。

手順 3 で出力されたバケット名(`s3t-prod-tfstate-{AWS_ACCOUNT_ID}`)を、次の手順で使います。

`backend.tf` の内容:

```hcl
terraform {
  backend "s3" {
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
terraform init -backend-config="bucket=s3t-prod-tfstate-$(aws sts get-caller-identity --query Account --output text)"
terraform fmt -recursive
terraform validate
terraform plan -var-file=terraform.tfvars
```

バケット名は手順 3 の出力に合わせてください。毎回入力したくない場合は、`backend.hcl`(`bucket = "..."` のみ記載、`.gitignore` に追加)を作り、`-backend-config=backend.hcl` で渡せます。

backend 設定や bucket を変更した場合は、必要に応じて再初期化します。

```bash
terraform init -reconfigure \
  -backend-config="bucket=s3t-prod-tfstate-$(aws sts get-caller-identity --query Account --output text)"
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

### 8-1. AWS アカウント ID を環境変数に設定する

アカウント ID はリポジトリに書かず、環境変数 `AWS_ACCOUNT_ID` から取得します。
[ansible/group_vars/all/vars.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vars.yml) と [ansible/inventories/aws_ec2.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/inventories/aws_ec2.yml) は `lookup('env', 'AWS_ACCOUNT_ID')` を使っており、未設定だとエラーになります。

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

`scripts/run_ansible.sh` と `scripts/run_drift_check.sh` は、未設定なら STS から自動取得するため、この手順は不要です。`ansible-playbook` や `ansible-inventory` を直接実行する場合のみ必要です。

この値は、SSM Session Manager のログバケット参照に使われます。

### 8-2. Vault 変数を確認する

[ansible/group_vars/all/vault.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vault.yml) には、Ansible Vault で扱う想定の値があります。

最低限確認したい項目:

- `vault_db_password`
- `vault_app_secret_key`
- `vault_chatwork_token`
- `chatwork_room_id`

Vault パスワードファイル `~/.vault_pass` を作成します。パスワードは `vault.yml` の暗号化に使ったものと同じ必要があります。
リポジトリ外に置き、権限は 600 にします。

```bash
stty -echo; printf "Vault password: "; read -r VP; stty echo; echo
printf '%s\n' "$VP" > ~/.vault_pass; unset VP
chmod 600 ~/.vault_pass
```

[ansible/ansible.cfg](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/ansible.cfg) の `vault_password_file` が `~/.vault_pass` を指しているため、`ansible-inventory --list` や `ansible-playbook` でもパスワード指定は不要です。
`--graph` は変数を展開しないので、パスワードがなくても動きます。

復号できるか確認します。

```bash
cd ansible
ansible-vault view group_vars/all/vault.yml
```

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

venv を有効にし、`ansible/` ディレクトリで実行します(リポジトリ直下では、インベントリが見つからず失敗します)。

```bash
source .venv/bin/activate
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
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

- `terraform init` に `-backend-config="bucket=..."` を渡していない
- 渡したバケット名が `bootstrap.sh` の出力と一致していない
- `bootstrap.sh` を実行していない
- 変更後に `terraform init -reconfigure` をしていない

### `NoCredentialProviders` や認証エラーが出る

- `aws sts get-caller-identity` が成功するか確認する
- SSO 利用時は `aws sso login` を再実行する

### `ansible-inventory` で boto3 / botocore の import エラーが出る

- `which ansible-inventory` が `/usr/bin/ansible-inventory` になっていないか確認する(system 版は venv の boto3 を使えない)
- venv を有効にして `pip install ansible-core boto3 botocore` を実行する
- 入れ直した後は `hash -r` を実行するか、新しいシェルを開く

### `ansible-inventory` で `unknown plugin 'amazon.aws.aws_ec2'` と出る

- `ansible-galaxy collection install -r ansible/requirements.yml` を、venv を有効にして実行する
- `ansible-galaxy collection list | grep amazon.aws` で入っているか確認する

### `ansible-inventory` で `Unable to parse ... as an inventory source` と出る

- 実行ディレクトリが `ansible/` になっているか確認する(リポジトリ直下で実行すると、パスが `./inventories/aws_ec2.yml` を指して失敗する)

### `Attempting to decrypt but no vault secrets found` と出る

- `~/.vault_pass` が存在するか確認する(手順 8-2 で作成)
- `ansible/` ディレクトリで実行しているか確認する(`ansible.cfg` の `vault_password_file` が読まれる)
- パスワードが `vault.yml` の暗号化に使ったものと一致するか、`ansible-vault view group_vars/all/vault.yml` で確認する

### `ansible-inventory` でホストが 0 台になる

- `terraform apply` 後に EC2 が起動済みか確認する
- EC2 タグ `Project=secure-3tier-iac-pipeline` と `Environment=prod` が付いているか確認する
- [ansible/group_vars/all/vars.yml](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ansible/group_vars/all/vars.yml) の `aws_account_id` 用に、環境変数 `AWS_ACCOUNT_ID` が設定されているか確認する

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

### `bootstrap.sh` で作成した tfstate バックエンドを削除する

`bootstrap.sh` が作った S3 バケットと DynamoDB テーブルは Terraform 管理外のため、`terraform destroy` では消えません。手動で削除します。

> **注意**: 必ず `terraform destroy` が完了した後に実行してください。先に消すと tfstate が失われ、残ったリソースを Terraform で削除できなくなります。

バケットはバージョニングが有効なため、`aws s3 rb --force` では削除できません。全バージョンと削除マーカーを消してからバケットを削除します。

```bash
BUCKET="s3t-prod-tfstate-$(aws sts get-caller-identity --query Account --output text)"
REGION="ap-northeast-1"

# 全バージョンを削除
aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' --output json)"

# 削除マーカーを削除
aws s3api delete-objects --bucket "$BUCKET" --region "$REGION" \
  --delete "$(aws s3api list-object-versions --bucket "$BUCKET" --region "$REGION" \
    --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' --output json)"

# バケットを削除
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION"

# ロック用 DynamoDB テーブルを削除
aws dynamodb delete-table --table-name s3t-prod-tfstate-lock --region "$REGION"
```

補足:

- 対象が空だと `delete-objects` が `Objects: null` でエラーになります。その場合は該当の手順を飛ばして構いません
- 1,000 件を超える場合は、同じコマンドを繰り返してください
- ローカルの `backend.hcl` を作った場合は、あわせて削除してください

## 関連ドキュメント

- [ARCHITECTURE.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/ARCHITECTURE.md)
- [terraform/envs/prod/README.md](/home/takuya/terraform-lab/secure-3tier-iac-pipeline/terraform/envs/prod/README.md)
