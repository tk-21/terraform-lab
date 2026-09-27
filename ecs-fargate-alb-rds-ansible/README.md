# ECS Fargate + ALB + RDS ハンズオン（Terraform + Ansible）

## このハンズオンで得られること

* **ECS Fargate の正しいデプロイフローの理解**
  TaskDefinitionの複製・書き換え・新revision登録・Service更新という、実務でも使う一連の流れを手を動かして体験できる
* **Dockerイメージを digest（sha256）指定でデプロイする安全な方法**
  タグ運用にありがちな「デプロイしたはずのイメージと実際に動いているものが違う」事故を構造的に防ぐ手法が身につく
* **Terraform（基盤）と Ansible（デプロイ）の責務分離という実務パターン**
  「IaCにアプリのビルドをさせない」設計思想を、実際に動くコードで理解できる
* **ALB → ECS → RDS の3層構成とセキュリティグループの最小権限設計**
  `alb-sg → ecs-sg → db-sg` という一方向の許可チェーンを、実際のTerraformコードで確認できる
* **失敗したときに自分で原因を切り分ける力**
  `services-stable` が終わらない、イメージが取得できない等、ECS運用で頻発するトラブルの見方が分かる
* **ECS one-off task（DBマイグレーション用タスク）の実行方法**
  Webサービス本体とは別に、コマンドを上書きして単発実行するタスクの組み方が分かる

> このリポジトリのより詳細な構成・設計判断・図解は [ARCHITECTURE.md](ARCHITECTURE.md) にまとめています。
> 「まず動かしたい」場合は本READMEを、「なぜこの設計なのか」を知りたい場合は ARCHITECTURE.md を参照してください。

---

このリポジトリは、
**Terraform で AWS 基盤を構築し、Ansible でアプリケーションを安全にデプロイする**
実務寄りのハンズオン環境です。

特に以下を重視しています。

* ECS / Fargate の正しいデプロイフロー理解
* **Docker image を digest 指定でデプロイする安全な方法**
* 「動かない理由がすぐ分かる」運用向け構成

---

## 全体像（何を作るか）

```
[Local PC]
  ├─ Terraform
  │    └─ VPC / ALB / ECS / RDS / IAM を作成
  │
  └─ Ansible
       └─ Docker build → ECR push → ECS deploy（digest指定）

                    ↓

          Application Load Balancer
                     ↓
               ECS Fargate Service
                     ↓
                  Container
                     ↓
                     RDS
```

図解付きの詳細なアーキテクチャは [ARCHITECTURE.md](ARCHITECTURE.md#1-システム全体像) を参照してください。

---

## なぜ Terraform + Ansible なのか？

| 領域    | ツール       | 理由                       |
| ----- | --------- | ------------------------ |
| AWS基盤 | Terraform | 再現性・差分管理                 |
| アプリ配布 | Ansible   | build/push/deploy を柔軟に制御 |
| ECS更新 | Ansible   | digest指定で安全に更新           |

> **Terraform にアプリのビルドをさせない**
> → IaC と デプロイの責務分離（実務で重要）

---

## ディレクトリ構成

```
.
├── terraform/
│   ├── modules/
│   │   ├── network/
│   │   ├── alb/
│   │   ├── ecs/
│   │   ├── rds/
│   │   └── ecr/
│   └── envs/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           ├── outputs.tf
│           └── terraform.tfvars.example
│
├── ansible/
│   ├── playbooks/
│   │   ├── deploy.yml
│   │   └── migrate.yml
│   └── group_vars/
│       └── dev.yml
│
└── app/
    ├── Dockerfile
    └── src/
```

---

## ハンズオン実行手順

以下は上から順番に実行してください。所要時間の目安は初回で **20〜30分程度**（RDS作成に数分かかります）。

### ステップ0. 事前準備

#### 必須ツール

| ツール       | 確認コマンド             | 補足 |
| --------- | ------------------- | --- |
| Terraform | `terraform version` | `>= 1.6.0` |
| Ansible   | `ansible --version` | `ansible-playbook` が使えること |
| Docker    | `docker version`    | `docker buildx` が使えること（Docker Desktop なら標準搭載） |
| AWS CLI   | `aws --version`     | v2 推奨 |
| jq        | `jq --version`      | buildx の出力解析・ECSタスク定義の加工に使用 |

#### AWS 認証情報

以下いずれかが設定されていること：

* `~/.aws/credentials`
* `AWS_PROFILE` 環境変数
* `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` 等の環境変数

確認：

```bash
aws sts get-caller-identity
```

意図しないAWSアカウントに向いていないか、ここで必ず確認してください。

---

### ステップ1. Terraform で AWS 基盤を構築

#### 1-1. 変数ファイルを用意する

`db_password` は必須変数（デフォルト値なし）です。テンプレートをコピーして値を設定してください。

```bash
cd terraform/envs/dev
cp terraform.tfvars.example terraform.tfvars
```

`terraform.tfvars` を開き、`db_password` を自分の値に変更します。
このファイルは `.gitignore` 対象なのでコミットされません。

> ⚠️ 学習用途のため RDS のパスワードは `terraform.tfvars` の平文変数として扱っています。
> `terraform apply` を実行すると **tfstate にも平文で残ります**。実務では Secrets Manager / RDS管理パスワードを使ってください（詳細は [ARCHITECTURE.md](ARCHITECTURE.md#7-既知のトレードオフ意図的な割り切り) 参照）。

#### 1-2. init → plan → apply

```bash
terraform init
terraform plan
terraform apply
```

`terraform plan` の出力で **作成されるリソース数・内容** を必ず確認してから `apply` してください。
（`make tf-apply` でも同様に `plan -out tfplan && apply tfplan` が実行されます）

#### 1-3. 作られる主なリソース

* VPC / Subnet（Public×2, Private×2）/ RouteTable / NAT Gateway
* ALB / TargetGroup / Listener
* ECS Cluster / Service（Fargate）/ TaskDefinition（app, migrate）
* ECR リポジトリ
* RDS（MySQL, Private Subnet配置）
* IAM Role（ECS Task Execution Role）

#### 1-4. 出力値を確認する

```bash
terraform output
# もしくは
make output
```

`ecr_repo_url` / `ecs_cluster_name` / `alb_dns_name` などが表示されれば成功です。
これらの値は次のAnsibleステップで自動的に読み込まれるため、手で控える必要はありません。

---

### ステップ2. Ansible の設定を確認する

`ansible/group_vars/dev.yml` に以下が定義されています（通常はそのままでOK）。

```yaml
tf_dir: "{{ playbook_dir }}/../../terraform/envs/dev"
app_dir: "{{ playbook_dir }}/../../app"

# デフォルトは date ベース。git があるなら git sha に変えてOK
image_tag: "{{ lookup('pipe', 'date +%Y%m%d%H%M%S') }}"

# migration のコマンド（あなたのアプリに合わせて差し替え）
migrate_command: "echo 'migrate placeholder'; exit 0"
```

* `tf_dir` / `app_dir`：Terraformの出力・アプリのソースをどこから読むか
* `image_tag`：ビルドのたびに変わるタグ（実際にECSへ渡すのは後述の digest）
* `migrate_command`：`make migrate` 実行時にコンテナ内で実行されるコマンド（現状は placeholder）

---

### ステップ3. デプロイを実行する（最重要）

```bash
cd ansible
ansible-playbook -i localhost, playbooks/deploy.yml
# もしくは
make deploy
```

#### 内部で何が起きているか

1. **Terraform outputs を取得**（クラスタ名・ECR URL・ALB DNS等をハードコードしない）
2. **前提コマンド確認**：`aws` / `docker` / `jq` の存在チェック、`aws sts get-caller-identity` でアカウント誤爆防止
3. **Docker build & ECR push**：`docker buildx build --push`
4. **push結果から digest を抽出**：`sha256:...` を取得し、タグではなく digest を正とする
5. **ECRへの反映を待機**：`describe-images` でdigestが見えるまでリトライ
6. **TaskDefinitionを複製・更新**：既存定義をコピーし、`image` だけ `repo@sha256:...` に差し替えて新revisionを登録
7. **ECS Serviceを更新**：`update-service --force-new-deployment`
8. **安定するまで待機**：`wait services-stable`（失敗時はECSイベントを自動表示）

より詳しいシーケンス図は [ARCHITECTURE.md](ARCHITECTURE.md#51-通常デプロイ-ansibleplaybooksdeployyml) を参照してください。

#### 成功時の表示

```
Deployed. ALB URL:
http://xxxx.ap-northeast-1.elb.amazonaws.com/
(health: /health)
```

---

### ステップ4. 動作確認

```bash
curl http://xxxx.elb.amazonaws.com/
curl http://xxxx.elb.amazonaws.com/health
```

* `/` → `hello from ecs`
* `/health` → `ok`

どちらも200が返れば、ALB → ECS Fargate → コンテナまで疎通が取れています。

---

### ステップ5. DBマイグレーションタスクを実行する（任意）

Webサービス本体とは別に、ECS Service に含まれない **one-off Task** としてマイグレーションを実行できます。

```bash
cd ansible
ansible-playbook -i localhost, playbooks/migrate.yml
# もしくは
make migrate
```

* `group_vars/dev.yml` の `migrate_command` がコンテナ内で実行されます（デフォルトは placeholder）
* Terraform outputs から Private Subnet / セキュリティグループを取得し、ECS Service と同じネットワーク条件でタスクを起動します
* 実行後、`aws ecs wait tasks-stopped` でタスク終了を待ち、`exitCode` / `reason` を表示します

実際のマイグレーションコマンドを実行したい場合は、`ansible/group_vars/dev.yml` の `migrate_command` を
自分のアプリのマイグレーションコマンド（例: `npm run migrate`）に書き換えてください。

---

### ステップ6. 後片付け

このハンズオンで作成したリソース（特に NAT Gateway / ALB / RDS）は起動しているだけで課金が発生します。
不要になったら以下を実行してください（**ユーザー自身で実行**、Claude Codeは実行しません）。

```bash
cd terraform/envs/dev
terraform destroy
```

---

## よくあるトラブルと見方

### ❌ `CannotPullContainerError`

* 原因：タグ指定 / ECR反映ラグ
* 対策：**digest指定（本構成で解決済）**

---

### ❌ `services-stable` が終わらない

```bash
aws ecs describe-services \
  --cluster <cluster> \
  --services <service> \
  --query 'services[0].events[0:10]'
```

よくある原因：

* ALB ヘルスチェック失敗
* 環境変数不足
* NAT / SG / DNS

---

### ❌ `terraform apply` が `db_password` を要求してくる

`terraform.tfvars` を作成し忘れています。[ステップ1-1](#1-1-変数ファイルを用意する) を参照してください。

---

### ❌ `migrate.yml` がネットワーク設定エラーで失敗する

Terraform outputs に `private_subnet_ids` / `ecs_service_security_group_id` が出力されている必要があります。
`terraform apply` 後に `terraform output` で両方の値が表示されるか確認してください（古いstateのままだと出力されません）。

---

## この構成の強み

* ✅ タグブレしない
* ✅ ローカル / CI どちらでも動く
* ✅ 失敗時の原因がすぐ分かる
* ✅ 実務にそのまま流用できる

---

## 次にやると良いこと（発展）

* Blue/Green（CodeDeploy）
* GitHub Actions 化
* Parameter Store / Secrets Manager 連携（RDSパスワードのstate平文問題の解消）
* HTTPS化（ACM + ALB HTTPS Listener）

より詳しい発展余地は [ARCHITECTURE.md](ARCHITECTURE.md#10-今後の発展余地) を参照してください。

---

## まとめ

このリポジトリは：

> **「Terraform × Ansible × ECS の正しい分業と運用を体験する」**

ためのハンズオンです。

「動いた」だけでなく、
**なぜ安全なのか / なぜ失敗しにくいのか**を理解できる構成になっています。
