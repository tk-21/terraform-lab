# terraform-lab

AWS インフラの設計・構築・運用を、Terraform を中心に検証したポートフォリオです。

リソースを作成するだけでなく、**即実用可能・セキュリティ優先・コスト意識あり**を設計原則とし、認証、監視、テスト、障害調査、削除までを含む構成を目指しています。

## Featured Projects

最初に見ていただきたい3作品です。

| プロジェクト | 解決する課題 | 主な技術 | 設計上のポイント |
|---|---|---|---|
| [EKS Golden Node Pipeline](./eks-golden-node-pipeline) | セキュアで再現可能な EKS ノードイメージの継続的な作成と更新 | Terraform, EKS, Karpenter, Packer, Ansible, GitHub Actions | CIS Benchmark、OIDC、Golden AMI、Spot、Graviton |
| [AWS Multilayer Firewall](./aws-multilayer-firewall-terraform) | AWS ネットワークにおける多層防御と通信制御の検証 | Terraform, NACL, Security Group, Network Firewall, WAF, SSM | 防御層の責務分離、許可・拒否テスト、ブロックログ、コスト比較 |
| [Bedrock AI Platform Sandbox](./bedrock-ai-platform-sandbox) | 予算制約のある環境でのセキュアな生成 AI 基盤 | Terraform, Bedrock, Lambda, API Gateway, Aurora, CloudWatch | マルチテナント、最小権限、可観測性、予算・トークン使用量制御 |

EKS プラットフォーム全体の設計については、[Terraform EKS Production Platform](./terraform-eks-production-platform) も参照してください。Private Subnet、IRSA、KMS、ALB、CloudWatch、AMP、Grafanaを含む本番基盤の雛形です。

## Engineering Principles

### 1. 即実用可能

コードだけで完結させず、構築後の確認と運用まで再現できることを重視しています。

- `terraform/` と再利用可能な `modules/` による構成管理
- READMEとアーキテクチャ資料による前提条件・構築手順・設計判断の明文化
- CloudWatch Logs、メトリクス、アラームを使った可観測性
- 疎通確認、拒否系テスト、Pod起動確認などの動作確認手順
- トラブルシューティング、停止・削除手順までを含むライフサイクル設計

代表例:

- [EKS Golden Node Pipeline](./eks-golden-node-pipeline): AMI作成からKarpenterによるノード起動、Pod配置確認までを一気通貫で実施
- [Terraform EKS Production Platform](./terraform-eks-production-platform): ネットワーク、EKS、配備、監視をTerraformで統合管理
- [AWS Multilayer Firewall](./aws-multilayer-firewall-terraform): SSM経由で許可通信と拒否通信を確認するテストを用意

### 2. セキュリティ優先

アクセスキーに依存しない認証、最小権限、暗号化、ネットワーク分離を基本方針としています。

- GitHub ActionsからAWSへの認証にOIDCを使用
- IAMロールの用途分離と最小権限化
- EC2・EKSノードなどのワークロードをPrivate Subnetへ配置
- KMSおよび各サービスの暗号化機能を利用
- WAF、Network Firewall、Security Group、NACLの責務を分離
- 許可される通信だけでなく、拒否されるべき通信もテスト

代表例:

- [EKS Golden Node Pipeline](./eks-golden-node-pipeline): CIS Benchmark Level 1、OIDC、IRSA、Golden AMI
- [AWS Multilayer Firewall](./aws-multilayer-firewall-terraform): NACLからWAFまでの多層防御とブロックログ確認
- [Security Hub AI Triage](./security-hub-ai-triage): Security Hub Findingのイベント駆動トリアージと監査用保存

### 3. コスト意識

単に低価格なサービスを選ぶのではなく、予算、利用量、可用性とのトレードオフを明示することを重視しています。

- Spot Instance、Graviton/arm64、Karpenterによるコンピュート最適化
- Lambdaなどのサーバーレス構成によるアイドルコストの抑制
- AWS Budgets、使用量監視、CloudWatchによる予算管理
- 検証に必要な概算費用と、停止・削除手順の明記
- 1AZとMulti-AZ、NAT Gateway、VPC Endpointなどのコストと可用性の比較

代表例:

- [Bedrock AI Platform Sandbox](./bedrock-ai-platform-sandbox): 月額予算、トークン上限、Budget Alert、Cost Controller
- [EKS Golden Node Pipeline](./eks-golden-node-pipeline): SpotとGravitonを利用したノードコスト最適化
- [AWS Multilayer Firewall](./aws-multilayer-firewall-terraform): 高額になりやすいNetwork Firewallを含む月額・時間単位の費用試算

## Evidence and Scope

各プロジェクトでは、可能な範囲で次の証跡を残しています。

- アーキテクチャ図と設計判断
- Terraformの入力、出力、バージョン制約
- 構築・動作確認手順と期待結果
- テストスクリプト、ログ確認方法、トラブルシューティング
- コスト試算と削除手順
- GitHub Actionsによる自動検証・ビルド

プロジェクトごとに検証範囲は異なります。実環境での動作確認、`terraform plan`までの確認、静的解析、設計検証を区別し、各READMEに記載します。本リポジトリは商用環境への無条件な適用を保証するものではありません。

## Technology Stack

| 分野 | 主な技術 |
|---|---|
| Infrastructure as Code | Terraform, AWS CDK, Pulumi, CloudFormation |
| AWS | VPC, IAM, EKS, ECS, Lambda, S3, RDS/Aurora, DynamoDB, EventBridge, Step Functions, Bedrock |
| Security | Security Hub, AWS Config, WAF, Network Firewall, GuardDuty, KMS, OIDC, IRSA |
| Containers / Platform | Docker, Kubernetes, EKS, Karpenter, Argo CD, Istio, Crossplane |
| Configuration / Image | Ansible, Packer |
| CI/CD / Quality | GitHub Actions, TFLint, Checkov, pytest, Go test |
| Observability | CloudWatch, X-Ray, AMP, Grafana |

## Project Catalog

代表作以外は、特定テーマの設計・比較・検証を行った補助ポートフォリオです。

<details>
<summary><strong>AI / Bedrock / MLOps</strong></summary>

- [knowledge-bot](./knowledge-bot) — FastAPI + Bedrock Knowledge Baseによる社内ナレッジQ&Aアプリ
- [bedrock-agent-resource-reporter](./bedrock-agent-resource-reporter) — AWSリソース調査とレポート生成の自動化
- [bedrock-finops-automation](./bedrock-finops-automation) — Cost Explorer + BedrockによるFinOps自動化
- [bedrock-multi-agent-ops-autopilot](./bedrock-multi-agent-ops-autopilot) — Bedrock Multi-Agent CollaborationによるAWS運用支援
- [aws-infra-review-ai](./aws-infra-review-ai) — Terraformコードとアーキテクチャの複数観点レビュー
- [iac-drift-detective](./iac-drift-detective) — インフラドリフトの検知・分析・修正案作成
- [iam-least-privilege-advisor](./iam-least-privilege-advisor) — IAM過剰権限の検出と最小権限案の作成
- [ansible-playbook-ai-reviewer](./ansible-playbook-ai-reviewer) — Ansible Playbookの自動レビュー
- [ai-inference-pipeline](./ai-inference-pipeline) — Step FunctionsとECS Fargateを使ったAI推論パイプライン
- [eks-chaos-postmortem-generator](./eks-chaos-postmortem-generator) — EKS障害実験とポストモーテム生成
- [sagemaker-mlops-pipeline](./sagemaker-mlops-pipeline) — モデル非依存のMLOpsパイプライン

</details>

<details>
<summary><strong>Data / Event-Driven / Streaming</strong></summary>

- [streaming-analytics-sandbox](./streaming-analytics-sandbox) — Kinesis、Firehose、Glue、Athenaによるストリーミング分析
- [event-driven-pipeline-sandbox](./event-driven-pipeline-sandbox) — SQS、Step Functions、DynamoDB Streamsによるイベント駆動処理
- [serverless-event-pipeline](./serverless-event-pipeline) — サーバーレスイベント処理基盤
- [iot-stream-pipeline](./iot-stream-pipeline) — IoTストリームデータ処理
- [order-pipeline-lab](./order-pipeline-lab) — オーダー処理パイプライン
- [vpc-lattice-msk-flink-streaming-platform](./vpc-lattice-msk-flink-streaming-platform) — VPC Lattice、MSK、Flinkによるストリーミング基盤
- [global-accelerator-firehose-databrew-platform](./global-accelerator-firehose-databrew-platform) — グローバルトラフィックとリアルタイムETLの検証

</details>

<details>
<summary><strong>Security / Compliance / SRE</strong></summary>

- [secure-3tier-iac-pipeline](./secure-3tier-iac-pipeline) — Terraform + Ansibleによるセキュアな3層Web基盤
- [waf-cloudfront-security-lab](./waf-cloudfront-security-lab) — WAF + CloudFrontのWebセキュリティ検証
- [config-securityhub-auto-remediation](./config-securityhub-auto-remediation) — AWS Config + Security Hubによる自動修復
- [self-healing-infra](./self-healing-infra) — Security Groupドリフトの検知と修復
- [chaos-engineering-lab](./chaos-engineering-lab) — AWS FISを使った障害実験
- [ecs-chaos-lab](./ecs-chaos-lab) — ECS Fargateの障害シナリオ検証
- [eks-chaos-cell](./eks-chaos-cell) — Cell-Based EKSの障害分離検証

</details>

<details>
<summary><strong>Containers / Platform / EKS</strong></summary>

- [ecs-dev](./ecs-dev) — ECSの基礎・応用検証
- [ecs-fargate-alb-rds-ansible](./ecs-fargate-alb-rds-ansible) — ECS Fargate、ALB、RDS、Ansibleの統合
- [docker-cicd-pipeline-lab](./docker-cicd-pipeline-lab) — ECS FargateへのBlue/Greenデプロイ
- [eks-handson](./eks-handson) — EKSとGitOpsの基礎検証
- [eks-ai-inference-platform](./eks-ai-inference-platform) — EKS上のAI推論基盤
- [ecs-eks-deepdive-lab](./ecs-eks-deepdive-lab) — ECSとEKSの比較検証
- [eks-performance-tuning](./eks-performance-tuning) — EKSとKarpenterの性能最適化
- [k8s-idp-lab](./k8s-idp-lab) — Crossplane、Argo CD、BackstageによるIDP
- [istio-eks-service-mesh](./istio-eks-service-mesh) — EKS上のIstioサービスメッシュ
- [serverless-api-platform](./serverless-api-platform) — サーバーレスAPI基盤

</details>

<details>
<summary><strong>Network / Compute / Operations</strong></summary>

- [vpc-network-deepdive](./vpc-network-deepdive) — AWSネットワーク設計の深掘り
- [tgw-multi-vpc-lab](./tgw-multi-vpc-lab) — Transit GatewayによるマルチVPC接続
- [alb-asg-https](./alb-asg-https) — ALB、ASG、HTTPS、WAF構成
- [lamp-fast](./lamp-fast) — LAMP構成
- [aurora-rds-proxy-lab](./aurora-rds-proxy-lab) — Aurora Serverless v2、RDS Proxy、Secrets Manager
- [terraform-ansible-ssm-alb-lab](./terraform-ansible-ssm-alb-lab) — Terraform、Ansible、SSM、ALBの統合
- [terraform-ansible-ssm-alb-asg-rds](./terraform-ansible-ssm-alb-asg-rds) — ASGとRDSを含むWeb基盤
- [terraform-ansible-aws-platform](./terraform-ansible-aws-platform) — 2AZのWeb基盤
- [aws-lsyncd-sync-infra](./aws-lsyncd-sync-infra) — lsyncdによるWebコンテンツ同期
- [tf-ansible-nginx-pipeline](./tf-ansible-nginx-pipeline) — nginx構成と継続的テスト
- [mail-infra-handson](./mail-infra-handson) — AWSメールインフラ
- [zabbix-lab](./zabbix-lab) — Zabbix監視環境

</details>

<details>
<summary><strong>IaC Workflow / Comparison</strong></summary>

- [terraform-aws-iac-workflow](./terraform-aws-iac-workflow) — TerraformのIaCワークフロー
- [pr-driven-iac-lab](./pr-driven-iac-lab) — PRを起点としたTerraformワークフロー
- [iac-trilogy-lab](./iac-trilogy-lab) — Terraform、Pulumi、AWS CDKの比較
- [cloud-agnostic-infra-lab](./cloud-agnostic-infra-lab) — AWS、GCP、Azureの比較検証
- [terraform-handson](./terraform-handson) — AWS主要サービスを使ったTerraform基礎

</details>

## Repository Policy

- プロジェクト固有のモジュールは原則として各ディレクトリ内に閉じる
- 認証はOIDCを優先し、長期アクセスキーをコードや設定へ保存しない
- 秘密情報、Terraform state、ローカル変数ファイルはコミットしない
- インフラ変更を伴うコマンドは内容を確認してから実行する

## How to Read This Repository

1. 上のFeatured Projectsから、関心のあるテーマを選ぶ
2. 各プロジェクトのREADMEで課題、構成、設計判断を確認する
3. `ARCHITECTURE.md`、ADR、コスト試算で判断理由を確認する
4. Terraformコード、テスト、GitHub Actionsで実装との整合性を確認する
