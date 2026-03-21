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

### AI / Bedrock

- [bedrock-ai-platform-sandbox](./bedrock-ai-platform-sandbox): エンタープライズ相当のAI基盤をTerraformで構築する学習・ポートフォリオ用プロジェクト（マルチテナント・WAF・Bedrock Agent・可観測性・CI/CD を全て含む）
- [knowledge-bot](./knowledge-bot): FastAPI + Bedrock Knowledge Base を使った社内ナレッジQ&Aアプリ。EKS上で動作しブラウザUIを持つ
- [bedrock-agent-resource-reporter](./bedrock-agent-resource-reporter): Bedrock Agent を使ったAWSリソースレポート自動生成
- [bedrock-finops-automation](./bedrock-finops-automation): Bedrock を活用したFinOps（コスト最適化）自動化

### Data / Streaming

- [streaming-analytics-sandbox](./streaming-analytics-sandbox): Kinesis + Firehose + Glue + Athena によるストリーミング分析基盤。API Gateway → KDS 直接統合（Lambda ゼロ）

### Event-Driven

- [event-driven-pipeline-sandbox](./event-driven-pipeline-sandbox): SQS + Step Functions + DynamoDB Streams によるイベント駆動パイプライン。Lambda 最小化設計

### Compute / Web

- [alb-asg-https](./alb-asg-https): ALB + ASG + HTTPS + WAF を扱う Terraform 構成
- [lamp-fast](./lamp-fast): LAMP 構成の検証環境
- [terraform-ansible-ssm-alb-lab](./terraform-ansible-ssm-alb-lab): Terraform + Ansible + SSM + ALB の検証構成
- [terraform-ansible-ssm-alb-asg-rds](./terraform-ansible-ssm-alb-asg-rds): Terraform + Ansible + SSM + ALB + ASG + RDS

### Containers / Platform

- [ecs-dev](./ecs-dev): ECS 関連の開発用構成
- [ecs-fargate-alb-rds-ansible](./ecs-fargate-alb-rds-ansible): ECS Fargate + ALB + RDS + Ansible の検証構成
- [eks-handson](./eks-handson): EKS ハンズオン用構成

### Operations / Monitoring

- [zabbix-lab](./zabbix-lab): Zabbix 検証環境

### Workflow / Practices

- [terraform-aws-iac-workflow](./terraform-aws-iac-workflow): Terraform の IaC ワークフロー検証

---

## bedrock-ai-platform-sandbox vs knowledge-bot

どちらも Amazon Bedrock + Knowledge Base を使うプロジェクトですが、目的と設計が異なります。

| 観点 | bedrock-ai-platform-sandbox | knowledge-bot |
|---|---|---|
| **コンセプト** | エンタープライズAI基盤の設計・学習 | 実際に使えるQ&Aボット（プロダクト寄り） |
| **実行基盤** | Lambda（サーバーレス） | EKS（Kubernetes + FastAPI） |
| **ベクトルDB** | Aurora pgvector | OpenSearch Serverless (AOSS) |
| **ルーティング** | Haiku / Sonnet 自動振り分け（複雑度判定） | 固定モデル（Claude Sonnet） |
| **マルチテナント** | あり（DynamoDB でトークン上限管理） | なし |
| **WAF** | あり（API Gateway v2 に統合） | あり（ALB Ingress） |
| **ブラウザUI** | なし（REST APIのみ） | あり（`/ask` エンドポイント + HTML） |
| **コスト上限** | 月$30（AWS Budgets + Cost Controller Lambda） | 明示なし |
| **Terraform構成** | `environments/dev/` + `modules/` に分離 | `infra/` にフラット配置 |

### どちらを参照すべきか

- Terraform モジュール設計・マルチテナント・可観測性を学びたい → **bedrock-ai-platform-sandbox**
- Bedrock KB を使ったアプリを EKS でサービングする方法を学びたい → **knowledge-bot**

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
