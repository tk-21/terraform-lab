# セットアップ時のトラブルシューティング記録

このドキュメントは、GitHub Actions OIDC、Packer、Terraform を初回セットアップした際に発生したエラーと、その原因・解決方法を記録するものです。

## 前提となる構成

- GitHub リポジトリ: monorepo
- プロジェクト: `eks-golden-node-pipeline/`
- CI: GitHub-hosted Runner
- AMI ビルド: Packer `amazon-ebs` builder + Ansible
- AWS リージョン: `ap-northeast-1`

## 実施順序

初回構築では、次の順序にする必要があります。

1. GitHub Actions OIDC 用 IAM Role と permissions policy を作成する
2. Terraform で VPC だけを bootstrap する
3. public subnet を GitHub Secret に設定する
4. Packer で Golden AMI を作成する
5. AMI ID を `golden_ami_id` として渡し、Terraform 全体を plan / apply する

VPC が必要な Packer と、Golden AMI を参照する Karpenter の間に依存関係があるため、初回だけは VPC を先行作成する。

## GitHub Actions の失敗ログを確認する

workflow の実行一覧を表示する。

```bash
gh run list --workflow ami-build.yml --limit 10
```

対象の実行 ID（`RUN_ID`）が分かったら、失敗したステップのログだけを取得する。

```bash
gh run view RUN_ID --log-failed
```

すべてのログが必要な場合は `--log` を使う。

```bash
gh run view RUN_ID --log
```

実行中の workflow は次のコマンドで監視できる。

```bash
gh run watch RUN_ID
```

`RUN_ID` を省略した `gh run watch` は対話形式で実行を選択する。Packer の失敗はログ量が多いため、最初は `--log-failed` を使い、必要な場合だけ `--log` を取得する。

## 1. GitHub Actions が workflow を見つけられない

### エラー

```text
HTTP 404: workflow ami-build.yml not found on the default branch
```

### 原因

GitHub Actions は GitHub リポジトリ直下の `.github/workflows/` だけを認識する。monorepo のサブディレクトリである `eks-golden-node-pipeline/.github/workflows/` に置いた workflow は認識されない。

### 解決

workflow をリポジトリ直下へ配置する。

```text
terraform-lab/.github/workflows/ami-build.yml
```

workflow 内では、各コマンドの `working-directory` を `eks-golden-node-pipeline` または `eks-golden-node-pipeline/packer` に明示する。

## 2. OIDC trust policy のリポジトリ指定

### 原因

OIDC の `sub` 条件はサブディレクトリ単位ではなく、GitHub リポジトリ単位で評価される。

### 解決

monorepo が `OWNER/REPOSITORY` の場合、trust policy には次を指定する。

```json
"token.actions.githubusercontent.com:sub": "repo:OWNER/REPOSITORY:ref:refs/heads/main"
```

`eks-golden-node-pipeline` のようなサブディレクトリ名は含めない。workflow の `paths` と `working-directory` でプロジェクトを限定する。

## 3. Ansible の Python パッケージと Collection が不足する

### エラー

```text
No matching distribution found for ansible==2.15.*
```

```text
couldn't resolve module/action 'ansible.posix.sysctl'
```

### 原因

- `2.15` は `ansible` パッケージではなく `ansible-core` のバージョン
- `ansible.posix` と `community.general` は Ansible Core に同梱されない Collection

### 解決

GitHub Actions の各ジョブで仮想環境を作成し、Ansible Core と必要 Collection をインストールする。

```bash
python3 -m venv .venv
.venv/bin/pip install --upgrade pip
.venv/bin/pip install "ansible-core==2.15.13"
.venv/bin/ansible-galaxy collection install \
  "ansible.posix:==1.5.4" \
  "community.general:==8.6.0"
```

## 4. Packer が Ansible playbook / role を見つけられない

### エラー

```text
playbook_file: ../ansible/playbooks/golden-ami.yml is invalid
```

```text
the role 'cis-benchmark' was not found
```

### 原因

Packer テンプレート内の `../ansible/...` は、Packer を `packer/` ディレクトリで実行する前提の相対パスである。また、Ansible 構文チェックをプロジェクト直下から実行すると `ansible/ansible.cfg` が自動検出されない。

### 解決

- Packer の `init`、`validate`、`build` は `eks-golden-node-pipeline/packer` を作業ディレクトリにする
- Ansible の構文チェックは `eks-golden-node-pipeline/ansible` を作業ディレクトリにする

```bash
# packer/ で実行
packer init golden-ami.pkr.hcl
packer validate golden-ami.pkr.hcl

# ansible/ で実行
ansible-playbook --syntax-check -i inventory/packer_hosts playbooks/golden-ami.yml
```

## 5. OIDC Role ARN が不正

### エラー

```text
Could not assume role with OIDC: Request ARN is invalid
```

### 原因

workflow が使用する `AWS_ACCOUNT_ID` Secret が未設定、または 12 桁の AWS アカウント ID 以外の値だった。

### 解決

GitHub の Repository Secret に `AWS_ACCOUNT_ID` を登録する。値は数字 12 桁のみとする。

```bash
aws sts get-caller-identity --query Account --output text
```

## 6. Packer Role の EC2 権限が不足

### エラー

```text
UnauthorizedOperation: not authorized to perform: ec2:DescribeImages
```

### 原因

Trust policy は OIDC による Role 引き受けだけを許可する。Packer が AMI を検索・作成する EC2 権限は別の identity-based policy として付与する必要がある。

### 解決

`eks-golden-node-pipeline-github-actions-role` に `PackerGoldenAmiBuild` permissions policy を追加する。ポリシー全文は [README の Packer 用 permissions policy](../README.md#2-3-packer-用の-permissions-policy-を追加する) を参照する。

## 7. Packer が subnet を見つけられない

### エラー

```text
No Subnets was found matching filters
```

### 原因

`subnet_id` が空で、テンプレートの `tag:Name = *private*` フィルターに一致する subnet を検索した。しかし、該当タグの subnet が存在しない、または GitHub-hosted Runner から SSH 到達できない private subnet を選ぼうとしていた。

### 解決

public subnet の ID を `PACKER_SUBNET_ID` Secret に登録し、workflow から Packer へ `-var "subnet_id=..."` で渡す。Packer テンプレートには `associate_public_ip_address = true` を設定する。

public subnet は次のように確認できる。

```bash
aws ec2 describe-subnets \
  --region ap-northeast-1 \
  --filters "Name=vpc-id,Values=YOUR_VPC_ID" \
  --query 'Subnets[?State==`available`].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch,Tags[?Key==`Name`]|[0].Value]' \
  --output table
```

### SSH が private IP に接続してタイムアウトする場合

ログに次のような private IP が表示される場合がある。

```text
Using SSH communicator to connect: 10.x.x.x
Timeout waiting for SSH
```

`associate_public_ip_address = true` だけでは、Packer が SSH 接続先に public IP を選ばない場合がある。`amazon-ebs` source に次も設定する。

```hcl
communicator                 = "ssh"
associate_public_ip_address = true
ssh_interface                = "public_ip"
ssh_username                 = "ec2-user"
```

失敗した Packer ビルドは、一時インスタンス・一時 Security Group・一時キーペアを自動削除する。ログに `Terminating the source AWS instance`、`Deleting temporary security group`、`Deleting temporary keypair` が表示されていることを確認する。

### Ansible の SFTP 転送が失敗する場合

次のエラーは、Packer の Ansible provisioner が使用する既定の SFTP サーバーパスが Amazon Linux 2023 に存在しないことを示す。

```text
/usr/lib/sftp-server: No such file or directory
```

Amazon Linux 2023 では SFTP サーバーは `/usr/libexec/openssh/sftp-server` にある。Ansible provisioner に次を設定する。

```hcl
provisioner "ansible" {
  playbook_file = "../ansible/playbooks/golden-ami.yml"
  sftp_command  = "/usr/libexec/openssh/sftp-server -e"
  user          = "ec2-user"
}
```

`user` を指定しない場合、Ansible provisioner は Packer を実行している GitHub Runner のユーザー名を使おうとする。Amazon Linux 2023 の接続ユーザーである `ec2-user` を明示する。

SFTP のパスを修正しても、次のようにファイル転送が失敗する場合がある。

```text
failed to transfer file to .../source
```

このケースでは、SFTP サーバーは起動しているものの、Packer の Ansible proxy 経由の SFTP 転送が完了しない。Packer provisioner が生成する inventory は SFTP を優先するため、`golden-ami.pkr.hcl` で SFTP を無効化し、`ansible/ansible.cfg` で SSH の通常コマンド経路（`dd`）を使う `piped` 転送へ切り替える。

```hcl
use_sftp = false
```

```ini
ssh_transfer_method = piped
```

workflow は Packer 1.16 を使用し、テンプレートでは Amazon plugin 1.8 と Ansible plugin 1.1.6 系を指定する。変更後は必ず `packer init` を実行して plugin を更新する。

## 8. Terraform の `templatefile()` が YAML コメントで失敗する

### エラー

```text
Invalid expression; Expected the start of an expression
```

### 原因

`templatefile()` は YAML コメント内でも `${...}` を評価する。コメントに空の `${}` があったため、Terraform 式として解釈されて失敗した。

### 解決

コメントから空の `${}` を削除する。YAML コメントで Terraform の補間記法を説明する場合も、空の補間記法を記載しない。

## 9. Golden AMI が未作成で Terraform plan が失敗する

### エラー

```text
Your query returned no results
```

### 原因

`golden_ami_id` が空の場合、Karpenter モジュールは `golden-ami-eks-<EKS_VERSION>-*` を検索する。初回は AMI がまだないため、data source が 0 件となる。

### 解決

初回は VPC だけを bootstrap する。

```bash
terraform plan -target=module.vpc
terraform apply -target=module.vpc
```

Packer ビルド成功後に AMI ID を設定し、通常の plan を実行する。

```bash
export TF_VAR_golden_ami_id="ami-xxxxxxxxxxxxxxxxx"
terraform plan
```

`-target` は bootstrap 用の一回限りの操作であり、通常の Terraform 運用では使用しない。

## 次回の改善候補

- Packer 用の IAM policy を手作業ではなく Terraform で管理する
- Ansible Collection を `requirements.yml` に切り出し、CI とローカルで共通化する
- GitHub-hosted Runner からの SSH を避けるため、self-hosted Runner または SSM communicator に移行する
- `golden_ami_id` が未設定の初回に Karpenter を無効化できる bootstrap フラグを Terraform に追加する
