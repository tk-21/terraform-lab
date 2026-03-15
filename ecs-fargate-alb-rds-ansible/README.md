# ECS Fargate + ALB + RDS ハンズオン（Terraform + Ansible）
https://chatgpt.com/g/g-p-690ea2b2c5948191a108d07e18727e7f/c/6957b4b4-7110-8323-9ee4-ce3d5f4c3272

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
│   │   ├── vpc/
│   │   ├── alb/
│   │   ├── ecs/
│   │   └── rds/
│   └── envs/
│       └── dev/
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
│
├── ansible/
│   ├── playbooks/
│   │   └── deploy.yml
│   └── group_vars/
│       └── dev.yml
│
└── app/
    ├── Dockerfile
    └── src/
```

---

## 事前準備

### 必須ツール

| ツール       | 確認                  |
| --------- | ------------------- |
| Terraform | `terraform version` |
| Ansible   | `ansible --version` |
| Docker    | `docker version`    |
| AWS CLI   | `aws --version`     |
| jq        | `jq --version`      |

---

### AWS 認証情報

以下いずれかが設定されていること：

* `~/.aws/credentials`
* `AWS_PROFILE`
* `AWS_ACCESS_KEY_ID` 等の環境変数

確認：

```bash
aws sts get-caller-identity
```

---

## 手順① Terraform で基盤構築

```bash
cd terraform/envs/dev

terraform init
terraform plan
terraform apply
```

### 作られる主なリソース

* VPC / Subnet / Route
* ALB / TargetGroup / Listener
* ECS Cluster / Service（Fargate）
* RDS
* IAM Role（TaskExecutionRole）

---

## 手順② Ansible 用設定

### `ansible/group_vars/dev.yml`

```yaml
tf_dir: "../../terraform/envs/dev"
app_dir: "../../app"

# タグ（※ 実際の参照は digest）
image_tag: "{{ lookup('pipe','date +%Y%m%d%H%M%S') }}"
```

---

## 手順③ デプロイ実行（最重要）

```bash
cd ansible
ansible-playbook -i localhost, playbooks/deploy.yml
```

---

## Ansible deploy.yml がやっていること（超重要）

### 1️⃣ Terraform outputs を取得

* クラスタ名
* ECR URL
* ALB DNS
* リージョン

👉 **ハードコードしない**

---

### 2️⃣ Docker build & ECR push

```bash
docker buildx build --push
```

---

### 3️⃣ buildx の出力から **digest を取得**

```
sha256:xxxxxxxxxxxxxxxx...
```

* タグは使わない
* **repo@sha256:... を ECS に指定**

👉 **タグブレ事故を防止**

---

### 4️⃣ ECS TaskDefinition を再作成

* 既存 TaskDefinition をコピー
* image だけ digest に差し替え
* 新 revision を登録

---

### 5️⃣ ECS Service を更新

```bash
aws ecs update-service --force-new-deployment
```

---

### 6️⃣ Service が安定するまで待機

```bash
aws ecs wait services-stable
```

* 失敗したら ECS events を自動表示
* 原因調査がすぐできる

---

## 成功時の表示

```
Deployed. ALB URL:
http://xxxx.ap-northeast-1.elb.amazonaws.com/
(health: /health)
```

---

## 動作確認

```bash
curl http://xxxx.elb.amazonaws.com/
curl http://xxxx.elb.amazonaws.com/health
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

## この構成の強み

* ✅ タグブレしない
* ✅ ローカル / CI どちらでも動く
* ✅ 失敗時の原因がすぐ分かる
* ✅ 実務にそのまま流用できる

---

## 次にやると良いこと（発展）

* DB migrate を **ECS one-off task** で実行
* Blue/Green（CodeDeploy）
* GitHub Actions 化
* Parameter Store / Secrets Manager 連携

---

## まとめ

このリポジトリは：

> **「Terraform × Ansible × ECS の正しい分業と運用を体験する」**

ためのハンズオンです。

「動いた」だけでなく、
**なぜ安全なのか / なぜ失敗しにくいのか**を理解できる構成になっています。

---

必要であれば次は：

* README に **図（ASCII/PlantUML）追加**
* **migrate 用 playbook**
* **CI 版 README**

まで一気に整えられます。
