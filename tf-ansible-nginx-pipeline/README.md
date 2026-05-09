# tf-ansible-nginx-pipeline

Terraform で AWS インフラを作り、Ansible で EC2 上の nginx を構成し、GitHub Actions とテストで継続運用するハンズオンです。

このプロジェクトの狙いは、単に動かすことではなく、次の設計を自分の言葉で説明できるようになることです。

- Terraform と Ansible の責務分界
- tfstate を S3 + DynamoDB で安全に扱う理由
- SSH ではなく SSM Session Manager を使う運用
- Terraform → SSM Parameter Store → Ansible という設定値受け渡し
- 静的解析、Molecule、Terratest、InSpec、Drift 検知まで含めた品質保証

詳しい構成の全体像は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

## このハンズオンで得られること

このハンズオンを完了すると、次のことができるようになります。

- Terraform と Ansible をどう役割分担させるべきか説明できる
- Terraform の remote state を S3 + DynamoDB で管理する理由を理解できる
- SSH を使わず、SSM Session Manager で EC2 を安全に運用する考え方が分かる
- Terraform から Ansible へ設定値を渡すときに、SSM Parameter Store を使う設計意図を説明できる
- Ansible Role の冪等性を Molecule で検証する流れを体験できる
- Terratest、InSpec、Drift Detection を使って IaC の品質をどう守るかイメージできる
- GitHub Actions と OIDC を使った AWS 自動化の基本パターンを理解できる

## このハンズオンで出来上がるもの

- AWS 上に VPC、public/private subnet、NAT Gateway、SSM 用 VPC Endpoint を作成
- private subnet に EC2 を 1 台作成
- EC2 を SSM Session Manager 経由で管理
- Terraform が nginx 設定値を SSM Parameter Store に保存
- Ansible がその設定値を読み取り、EC2 に nginx を構成
- GitHub Actions で Terraform / Ansible / Drift Detection を自動化

## 最初に知っておくべきこと

このリポジトリは学習用としてかなり良く整理されていますが、現状の実装には次の前提があります。

- nginx は現状インターネット公開されません
  EC2 は private subnet にあり、ALB や public IP、HTTP 用インバウンド許可は未実装です。
- Ansible の SSM パラメータ参照先は `handson-dev` 固定です
  `dev` 以外の環境にそのまま横展開するには追加調整が必要です。
- GitHub Actions 用 IAM は学習用の最小構成寄りです
  実際に `terraform apply` を CI で完走させるには権限見直しが必要になる可能性があります。

## 学習ゴール

この README の手順をやり切ると、少なくとも次を説明できる状態を目指せます。

- なぜネットワークや EC2 は Terraform で管理するのか
- なぜ nginx 設定は Ansible に寄せるのか
- なぜ Terraform output を直接 Ansible に渡さず SSM パラメータを使うのか
- なぜ SSH ではなく SSM を使うのか
- IaC の品質をテストと Drift 検知でどう守るのか

## ディレクトリ構成

```text
tf-ansible-nginx-pipeline/
├── README.md
├── ARCHITECTURE.md
├── terraform/
│   ├── bootstrap/
│   ├── environments/dev/
│   └── modules/
│       ├── vpc/
│       ├── compute/
│       └── ssm/
├── ansible/
│   ├── inventory/
│   ├── roles/nginx/
│   └── site.yml
├── tests/
│   ├── terratest/
│   └── inspec/
├── docs/
└── .github/workflows/
```

## 前提条件

ローカルでハンズオンを進める前に、次が使える状態であることを確認してください。

- AWS CLI
- Terraform 1.7 以上
- Python 3
- Ansible 2.15 以上
- Go 1.21 以上
- Docker
- GitHub アカウントと対象リポジトリ

AWS 側の前提:

- 利用リージョンは `ap-northeast-1`
- Terraform 実行に必要な AWS 認証情報がローカルに設定済み
- 自分の AWS アカウント上で S3、DynamoDB、VPC、EC2、IAM、SSM を作成できる

## まず読むべきドキュメント

作業開始前に次をざっと読んでおくと、手順の意味がつかみやすいです。

1. [ARCHITECTURE.md](./ARCHITECTURE.md)
2. [docs/adr/ADR-001-terraform-ansible-boundary.md](./docs/adr/ADR-001-terraform-ansible-boundary.md)
3. [docs/terraform-state-deep-dive.md](./docs/terraform-state-deep-dive.md)
4. [docs/terraform-ansible-handoff.md](./docs/terraform-ansible-handoff.md)
5. [docs/testing-strategy.md](./docs/testing-strategy.md)

## 実行の全体フロー

このハンズオンは次の順で進めると分かりやすいです。

1. ローカル準備
2. Phase 1: tfstate 基盤の bootstrap
3. Phase 2: Terraform で dev 環境を作成
4. Phase 3: Ansible Role をローカルで検証
5. Phase 4: AWS 上の EC2 に nginx を構成
6. Phase 5: テストと Drift 検知を確認
7. GitHub Actions と OIDC を設定
8. クリーンアップ

---

## 1. ローカル準備

### 1-1. リポジトリに移動

```bash
cd /path/to/tf-ansible-nginx-pipeline
pwd
```

### 1-2. Python 仮想環境を作成

このプロジェクトでは Python 系ツールを使うので、まず `venv` を作成します。

```bash
python3 -m venv .venv
source .venv/bin/activate
which python
```

期待する状態:

- `.venv/` が作成されている
- `which python` が `.venv/bin/python` を指している

### 1-3. Python/Ansible 系ツールをインストール

このリポジトリには現状 `requirements.txt` がないため、まずは手動で最低限のツールを入れます。

```bash
pip install \
  ansible \
  ansible-lint \
  boto3 \
  botocore \
  amazon.aws \
  molecule \
  molecule-docker \
  docker
```

Ansible コレクションも入れておきます。

```bash
ansible-galaxy collection install amazon.aws community.aws
```

### 1-4. バージョン確認

```bash
terraform version
aws --version
ansible --version
go version
docker --version
```

### 1-5. AWS 認証確認

```bash
aws sts get-caller-identity
aws configure get region
```

確認ポイント:

- 想定アカウントを参照していること
- リージョンが `ap-northeast-1` であること

---

## 2. Phase 1: tfstate 基盤を bootstrap する

このフェーズでは、Terraform の remote state を安全に置くための S3 バケットと DynamoDB ロックテーブルを作成します。

### 2-1. bootstrap コードを読む

対象:

- [terraform/bootstrap/main.tf](./terraform/bootstrap/main.tf)
- [terraform/bootstrap/variables.tf](./terraform/bootstrap/variables.tf)
- [terraform/bootstrap/outputs.tf](./terraform/bootstrap/outputs.tf)

理解ポイント:

- なぜここだけ local state なのか
- なぜ S3 バケットに `prevent_destroy` を付けるのか
- なぜ DynamoDB をロック用途に使うのか

### 2-2. Terraform 初期化と検証

```bash
cd terraform/bootstrap
terraform init
terraform validate
terraform plan
```

ここで確認すること:

- `init` が通る
- `validate` が成功する
- `plan` に S3 バケットと DynamoDB テーブルの作成差分が出る

### 2-3. bootstrap を作成

```bash
terraform apply
```

### 2-4. 出力値を控える

```bash
terraform output
```

特に次の値を控えます。

- `tfstate_bucket_name`
- `tflock_table_name`

### 2-5. AWS コンソールで確認

次を確認してください。

- S3 バケット `handson-dev-tfstate` がある
- バージョニングが有効
- デフォルト暗号化が有効
- DynamoDB テーブル `handson-dev-tflock` がある

補足として、理解度チェックには [docs/phase1-checklist.md](./docs/phase1-checklist.md) が使えます。

---

## 3. Phase 2: Terraform で dev 環境を作る

このフェーズでは、VPC、subnet、NAT Gateway、SSM VPC Endpoint、EC2、SSM パラメータ、GitHub Actions OIDC 設定を dev 環境として作ります。

### 3-1. environment と modules を読む

最初に次を読むと全体がつかみやすいです。

- [terraform/environments/dev/main.tf](./terraform/environments/dev/main.tf)
- [terraform/environments/dev/github_actions_oidc.tf](./terraform/environments/dev/github_actions_oidc.tf)
- [terraform/modules/vpc/main.tf](./terraform/modules/vpc/main.tf)
- [terraform/modules/compute/main.tf](./terraform/modules/compute/main.tf)
- [terraform/modules/ssm/main.tf](./terraform/modules/ssm/main.tf)

### 3-2. dev 環境で初期化と検証

```bash
cd ../environments/dev
terraform init
terraform validate
terraform fmt -check -recursive
terraform plan
```

期待する差分のイメージ:

- VPC
- public/private subnet
- Internet Gateway
- NAT Gateway
- SSM 用 VPC Endpoint
- EC2
- IAM role / instance profile
- SSM Parameter
- GitHub Actions OIDC provider / role

### 3-3. dev 環境を作成

```bash
terraform apply
```

### 3-4. output を確認

```bash
terraform output
```

見ておきたい主な出力:

- `vpc_id`
- `private_subnet_ids`
- `instance_id`
- `ec2_security_group_id`
- `github_actions_role_arn`

### 3-5. AWS 側の確認ポイント

次をコンソールまたは CLI で確認してください。

- VPC が作成されている
- private subnet に EC2 が 1 台ある
- EC2 に `AnsibleManaged=true` と `Role=web` タグが付いている
- SSM Parameter Store に nginx 用パラメータがある
- EC2 が Systems Manager の managed instance として見える

CLI で確認する例:

```bash
aws ssm describe-instance-information --region ap-northeast-1
aws ssm get-parameter --name /handson-dev/nginx/port --region ap-northeast-1
```

---

## 4. Phase 3: Ansible Role をローカルで検証する

このフェーズでは、まず AWS 実機に当てる前に、Role 単体が正しく動くかを Molecule で確認します。

### 4-1. Ansible 設定を読む

対象:

- [ansible/site.yml](./ansible/site.yml)
- [ansible/ansible.cfg](./ansible/ansible.cfg)
- [ansible/inventory/aws_ec2.yml](./ansible/inventory/aws_ec2.yml)
- [ansible/roles/nginx/tasks/main.yml](./ansible/roles/nginx/tasks/main.yml)
- [ansible/roles/nginx/handlers/main.yml](./ansible/roles/nginx/handlers/main.yml)
- [ansible/roles/nginx/templates/nginx.conf.j2](./ansible/roles/nginx/templates/nginx.conf.j2)

理解ポイント:

- site.yml は入口だけで、処理は role に寄せている
- Inventory は `aws_ec2` プラグインを使う
- 接続方式は `aws_ssm`
- nginx 設定値は SSM パラメータから読む

### 4-2. Molecule テストを実行

```bash
cd ../../../ansible
molecule test
```

何を見ているか:

- Role が最後まで適用できるか
- 2 回目実行で不要な変更が出ないか
- `verify.yml` の検証を通るか

### 4-3. 冪等性だけ見たい場合

```bash
molecule converge
molecule idempotency
```

合格の目安:

- `changed=0`

---

## 5. Phase 4: AWS 上の EC2 に nginx を構成する

Terraform で作成した EC2 に対して、Ansible を SSM 経由で実行します。

### 5-1. Dynamic Inventory を確認

```bash
ansible-inventory --list
```

確認ポイント:

- `web` グループが生成される
- 対象ホストが instance-id で表示される

必要なら絞って確認します。

```bash
ansible-inventory --list | jq '.web'
```

### 5-2. 接続確認

```bash
ansible web -m ping
```

ここで失敗する場合は次を確認します。

- EC2 が SSM managed instance になっているか
- `amazon.aws` コレクションが入っているか
- ローカル AWS 認証情報で SSM と EC2 を読めるか

### 5-3. ドライラン

```bash
ansible-playbook site.yml --check --diff
```

見るポイント:

- nginx 設定や index 配置の差分が見える
- 意図しない変更がない

### 5-4. 本番適用

```bash
ansible-playbook site.yml
```

### 5-5. 適用後の確認

Ansible の `post_tasks` で `http://localhost/health` を確認しているので、Playbook 成功自体が一つの確認になります。

必要なら SSM 経由で追加確認します。

```bash
ansible web -m command -a "systemctl status nginx --no-pager"
ansible web -m command -a "curl -s http://localhost/health"
```

期待する状態:

- nginx サービスが起動している
- `/health` が `200 OK` を返す

---

## 6. Phase 5: テストと検証

ここでは「動いた」だけで終わらず、壊れたら気づける状態に近づけます。

### 6-1. 静的解析

```bash
cd ../terraform/environments/dev
terraform validate
terraform fmt -check -recursive

cd ../../../ansible
ansible-lint site.yml
```

### 6-2. Terratest

注意:

- 実 AWS リソースを作成するため課金が発生します
- テスト後は `t.Cleanup()` で destroy される前提です

```bash
cd ../tests/terratest
go test -v -timeout 30m -run TestVPCModule
```

AZ バリエーションだけ試したい場合:

```bash
go test -v -timeout 30m -run TestVPCModuleAZVariants
```

### 6-3. InSpec

InSpec が未導入なら先に入れます。

```bash
gem install inspec inspec-aws
```

実行:

```bash
cd ../inspec
inspec exec . -t aws://ap-northeast-1 --reporter cli json:report.json
```

### 6-4. Drift を手動確認

```bash
cd ../../terraform/environments/dev
terraform plan -detailed-exitcode
```

結果の見方:

- `0`: 差分なし
- `2`: Drift あり

テスト全体の補足は [docs/testing-runbook.md](./docs/testing-runbook.md) にまとめています。

---

## 7. GitHub Actions と OIDC を設定する

このプロジェクトには次のワークフローが入っています。

- [terraform.yml](./.github/workflows/terraform.yml)
- [ansible.yml](./.github/workflows/ansible.yml)
- [drift-detection.yml](./.github/workflows/drift-detection.yml)

### 7-1. GitHub Secrets に IAM ロール ARN を設定

Terraform apply 後に出力された `github_actions_role_arn` を GitHub の Secret に入れます。

設定場所:

- `Settings`
- `Secrets and variables`
- `Actions`
- `New repository secret`

名前:

```text
AWS_ROLE_ARN
```

値:

```bash
terraform output github_actions_role_arn
```

### 7-2. CI の流れを理解する

Terraform workflow:

- PR で `init / validate / fmt / plan`
- main push で `apply`

Ansible workflow:

- Terraform workflow 成功後に起動
- `ansible-lint`
- inventory 確認
- `--check --diff`
- 条件が合えば本番適用

Drift Detection:

- 毎日定時実行
- 差分があれば Issue 作成

### 7-3. 実際に試す

```bash
git checkout -b docs-or-test-branch
git add .
git commit -m "docs: add handson guide"
git push origin docs-or-test-branch
```

PR を作成し、Terraform plan コメントが付くことを確認します。

---

## 8. よくある詰まりどころ

### `ansible-inventory --list` でホストが出ない

確認ポイント:

- EC2 に `AnsibleManaged=true` タグがあるか
- EC2 が `running` か
- ローカル AWS 認証情報で `DescribeInstances` できるか

### `ansible web -m ping` が通らない

確認ポイント:

- EC2 が SSM Managed Instance になっているか
- IAM ロールに `AmazonSSMManagedInstanceCore` が付いているか
- VPC Endpoint または外向き通信が正しく構成されているか

### `terraform init` で backend 周りが失敗する

確認ポイント:

- bootstrap の `apply` を先に実施したか
- S3 バケット名と DynamoDB テーブル名が実在するか
- AWS 認証情報が正しいか

### Molecule が失敗する

確認ポイント:

- Docker が起動しているか
- `molecule-docker` が入っているか
- `amazonlinux:2023` イメージを pull できるか

### Terratest が長い、またはタイムアウトする

NAT Gateway や VPC Endpoint は作成に時間がかかります。30 分近くかかることもあるので、時間に余裕を持って実行してください。

---

## 9. 学習の確認ポイント

ハンズオン後に、少なくとも次に答えられるか確認してみてください。

1. なぜ Terraform output を直接 Ansible vars に書かないのか
2. なぜ EC2 に SSH インバウンドを開けていないのか
3. なぜ tfstate を S3 + DynamoDB で持つのか
4. なぜ nginx インストールを `user_data` ではなく Ansible に寄せているのか
5. 2 回目の Ansible 実行で `changed=0` であることにどんな意味があるのか

---

## 10. クリーンアップ

ハンズオン後は課金停止のため、必ず削除します。

### 10-1. dev 環境を削除

```bash
cd terraform/environments/dev
terraform destroy
```

### 10-2. tfstate バケットを空にする

bootstrap 側の S3 バケットには `prevent_destroy = true` があるため、先に中身を空にします。

```bash
aws s3 rm s3://handson-dev-tfstate --recursive
```

### 10-3. bootstrap リソースを削除

```bash
cd ../../bootstrap
terraform destroy
```

---

## 11. どこから読むと理解しやすいか

手を動かしたあとに読み返すなら、この順がおすすめです。

1. [ARCHITECTURE.md](./ARCHITECTURE.md)
2. [docs/adr/ADR-001-terraform-ansible-boundary.md](./docs/adr/ADR-001-terraform-ansible-boundary.md)
3. [docs/terraform-state-deep-dive.md](./docs/terraform-state-deep-dive.md)
4. [docs/terraform-ansible-handoff.md](./docs/terraform-ansible-handoff.md)
5. [docs/testing-strategy.md](./docs/testing-strategy.md)
6. [docs/testing-runbook.md](./docs/testing-runbook.md)

## 12. 一言でまとめると

このハンズオンは、

`Terraform が AWS 上の骨格を作り、Ansible が EC2 の中身を整え、SSM が両者の受け渡しを担い、CI とテストがその運用を支える`

という一連の流れを、設計理由つきで体験するためのプロジェクトです。
