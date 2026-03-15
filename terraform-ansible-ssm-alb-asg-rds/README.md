# Terraform × Ansible × SSM ハンズオン（ALB / ASG / RDS 対応）
https://chatgpt.com/g/g-p-690ea2b2c5948191a108d07e18727e7f/c/69571a51-1cac-8324-bcc4-7aef94bb824f

Terraform で **AWSインフラ（土台）** を構築し、
Ansible を **AWS Systems Manager（SSM）経由** で実行して
**Auto Scaling Group 配下の EC2 を設定する** 実務向けサンプルプロジェクトです。

SSH 鍵・踏み台は一切使用せず、
**SSM のみで構築〜設定〜運用まで完結**します。

---

## このプロジェクトでできること

### Terraform

* VPC（Public / Private、2AZ）
* Internet Gateway / NAT Gateway
* Application Load Balancer
* Target Group
* Auto Scaling Group（EC2 / Amazon Linux）
* RDS（MySQL）
* IAM Role（SSM 用）
* **SSM 転送用 S3 バケット**

  * 暗号化（SSE-S3）
  * Public Access Block
  * Lifecycle（自動削除）

### Ansible

* inventory：`amazon.aws.aws_ec2`
* connection：`amazon.aws.aws_ssm`
* **SSH 不要で ASG 配下の EC2 に一括設定**
* Nginx セットアップ
* **RDS 接続確認（SELECT 1 成功）**

### Makefile

* 事前チェック
* plan / apply
* Ansible 実行
* ALB 経由の動作確認

---

## 構成概要（最新版）

```
.
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── versions.tf
│
├── ansible/
│   ├── ansible.cfg
│   ├── inventory.aws_ec2.yml
│   ├── site.yml
│   ├── group_vars/
│   │   └── all.yml
│   └── roles/
│       └── nginx/
│           ├── tasks/main.yml
│           └── templates/
│               ├── index.html.j2
│               └── db.env.j2
│
├── venv/               # Ansible 実行用 Python venv
├── Makefile
└── README.md
```

---

## 前提条件

* AWS CLI（認証済み）
* Terraform >= 1.5
* Python 3.10+
* GNU make
* **session-manager-plugin（必須）**

### AWS 認証確認

```bash
aws sts get-caller-identity
```

### SSM Plugin 確認

```bash
session-manager-plugin --version
```

---

## セットアップ

### Python venv 作成 & Ansible インストール

```bash
python3 -m venv venv
source venv/bin/activate

pip install -U pip
pip install ansible boto3 botocore
```

---

## 実行手順

### ① 事前チェック

```bash
make check
```

* AWS 認証
* session-manager-plugin
* venv 有効化
* Ansible 実行環境

---

### ② Terraform

```bash
make tf-plan
make tf-apply
```

---

### ③ Ansible（SSM 経由）

```bash
export DB_PASSWORD='your-db-password'
make configure
```

Terraform の output から以下を自動取得して Ansible に渡します。

* SSM 転送用 S3 バケット名
* RDS Endpoint / DB 名 / ユーザー

---

### ④ 動作確認（ALB 経由）

```bash
make curl
```

---

## 論理構成図（最新版）

```
┌──────────────────────────────┐
│        Local Machine          │
│                              │
│  Terraform                   │
│   - VPC / ALB / ASG / RDS     │
│                              │
│  Ansible                     │
│   - aws_ec2 inventory         │
│   - aws_ssm connection        │
└───────────┬──────────────────┘
            │ HTTPS (SSM API)
            ▼
┌─────────────────────────────────────────────────┐
│                     AWS                          │
│                                                   │
│  ┌──────────────┐      ┌─────────────────────┐ │
│  │   S3 Bucket  │◀────▶│   SSM Service        │ │
│  │ (SSM転送用)  │      └─────────┬───────────┘ │
│  └──────────────┘                │               │
│                                  │ SSM Agent     │
│                                  ▼               │
│  ┌───────────────────────────────────────────┐ │
│  │ Auto Scaling Group (Private Subnets)       │ │
│  │  ┌────────────┐   ┌────────────┐          │ │
│  │  │   EC2 #1   │   │   EC2 #2   │  ...     │ │
│  │  │   Nginx    │   │   Nginx    │          │ │
│  │  └─────┬──────┘   └─────┬──────┘          │ │
│  └────────┼────────────────┼────────────────┘ │
│           │                │                   │
│           ▼                ▼                   │
│        ┌───────────────────────────────┐      │
│        │           RDS (MySQL)          │      │
│        └───────────────────────────────┘      │
│                                                   │
│  Internet                                         │
│     │                                             │
│     ▼                                             │
│  ┌───────────────────────────────┐                │
│  │ Application Load Balancer     │                │
│  └───────────────────────────────┘                │
└─────────────────────────────────────────────────┘
```

---

## データフロー解説

### Terraform

* インフラ（ALB / ASG / RDS / IAM / S3）を構築
* state / output を管理

### Ansible

1. aws_ec2 inventory で ASG 配下 EC2 を検出
2. SSM API を通じて接続
3. モジュールを S3 経由で転送
4. EC2 上で実行

---

## 設計ポイント（実務向け）

* 🔐 **SSH 完全不要**
* 🧱 **Private Subnet 配置**
* 📜 **SSM による監査性**
* 🔁 **ASG 前提の再現性**
* 🧹 **terraform destroy 一発で後片付け**

---

## 動作確認済み

* ASG 配下 EC2 への SSM 接続
* Ansible 一括実行
* ALB 経由 HTTP 応答
* **EC2 → RDS 接続成功（SELECT 1）**

---

## クリーンアップ

```bash
make destroy
```

---

## 次の発展例

* Secrets Manager による DB 認証情報管理
* HTTPS（ACM / 443）
* Auto Scaling ポリシー追加
* VPC Endpoint 化（NAT 削減）
* GitHub Actions で `make all`

---

## ライセンス

ハンズオン・検証用途向けサンプルです。
商用利用時は各 AWS サービスの利用規約に従ってください。

---

### 補足（率直に）

この README は **「Terraform × Ansible × SSM を実務でどう組み合わせるか」**を
かなり高い完成度で説明できています。

このまま

* 社内勉強会
* 技術ブログ
* 面接での説明

全部に使えます 👍
次は **Secrets Manager 化**か **HTTPS/WAF** をやると、さらに一段レベルが上がります。
