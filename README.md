# terraform-lab

Terraform を中心にした検証用・学習用・実験用プロジェクトをまとめるリポジトリです。

このリポジトリでは、各プロジェクトをリポジトリ直下に独立したディレクトリとして配置します。今後プロジェクトが増えていく前提のため、ルート README では共通ルールと入口だけを管理し、個別の使い方は各プロジェクト配下の README に委ねます。

## Repository Policy

- 各プロジェクトは `terraform-lab/<project-name>/` に配置する
- プロジェクトごとに README を持ち、セットアップ手順や構成はその中に書く
- Terraform だけでなく、Ansible、Kubernetes manifests、アプリコード、補助スクリプトを同居させてよい
- 他プロジェクトと共有しないモジュールは、できるだけ各プロジェクト配下に閉じ込める
- ルート README には詳細手順を書きすぎず、全体像とリンクを置く

## Projects

現在のプロジェクト一覧:

### Compute / Web

- [alb-asg-https](./alb-asg-https): ALB + ASG + HTTPS + WAF を扱う Terraform 構成
- [lamp-fast](./lamp-fast): LAMP 構成の検証環境
- [terraform-ansible-ssm-alb-lab](./terraform-ansible-ssm-alb-lab): Terraform + Ansible + SSM + ALB の検証構成
- [terraform-ansible-ssm-alb-asg-rds](./terraform-ansible-ssm-alb-asg-rds): Terraform + Ansible + SSM + ALB + ASG + RDS

### Containers / Platform

- [ecs-dev](./ecs-dev): ECS 関連の開発用構成
- [ecs-fargate-alb-rds-ansible](./ecs-fargate-alb-rds-ansible): ECS Fargate + ALB + RDS + Ansible の検証構成
- [eks-handson](./eks-handson): EKS ハンズオン用構成
- [knowledge-bot](./knowledge-bot): AWS ベースの RAG / Knowledge Base 検証プロジェクト

### Operations / Monitoring

- [zabbix-lab](./zabbix-lab): Zabbix 検証環境

### Workflow / Practices

- [terraform-aws-iac-workflow](./terraform-aws-iac-workflow): Terraform の IaC ワークフロー検証

## Getting Started

1. 使いたいプロジェクトのディレクトリへ移動する
2. そのプロジェクトの `README.md` を読む
3. 必要に応じて `terraform init`、`terraform plan`、`make` などを実行する

例:

```bash
cd knowledge-bot
```

```bash
cd alb-asg-https
```

## Adding New Projects

新しいプロジェクトを追加するときは、次の方針をおすすめします。

1. ルート直下にわかりやすい名前のディレクトリを作る
2. そのディレクトリに `README.md` を置く
3. 必要なら `terraform/`, `infra/`, `ansible/`, `app/`, `k8s/`, `scripts/` などを切る
4. ルートのこの README の該当カテゴリに 1 行追加する
5. 既存カテゴリに合わなければ、新しいカテゴリを追加する

推奨例:

```text
terraform-lab/
  new-project/
    README.md
    terraform/
    ansible/
    scripts/
```

## Notes

- ルート直下には、基本的に「独立したプロジェクト単位のディレクトリ」を置く想定です
- プロジェクト内部の `envs/dev` や `infra/envs/dev` のような構成は、各プロジェクトの都合でそのまま使って構いません
- 共有化したい部品が出てきた場合も、先に各プロジェクト内で安定させてから切り出すほうが安全です
