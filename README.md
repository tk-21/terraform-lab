# terraform-lab

Terraformを中心に、AWSインフラの設計・構築・運用方法を個人で検証したポートフォリオです。

VPC・EC2・RDS・ALBなどの基礎構成から、ECS/EKS、CI/CD、セキュリティ、生成AI、カオスエンジニアリングまで、実際にコードを書いて検証しています。

> [!NOTE]
> 本リポジトリは個人学習・技術検証を目的としており、商用環境での運用実績を示すものではありません。実運用を想定し、セキュリティ、監視、障害対応、コスト、構築後の削除まで含めて設計しています。

## 主な検証内容

これまでに検証した内容を分野ごとにまとめています。

| 検証領域 | 検証内容 | 主な成果物 |
|---|---|---|
| Terraform基礎 | VPC、EC2、RDS、ALB、Auto Scalingの段階的な構築、module化、S3 BackendとDynamoDB Lockによるstate管理 | [terraform-handson](./terraform-handson) |
| コンテナ | ECS Fargate、ALB、RDSをTerraformで構築し、Ansibleと組み合わせて検証 | [ecs-fargate-alb-rds-ansible](./ecs-fargate-alb-rds-ansible) |
| EKS・生成AI | FastAPIとBedrock Knowledge Baseを利用したRAGアプリをEKS上に構築し、IRSAでAWS権限を付与 | [knowledge-bot](./knowledge-bot) |
| 発展検証 | AWS FIS、PR起点のIaCワークフロー、AWS・GCP・Azureの同一構成比較 | [chaos-engineering-lab](./chaos-engineering-lab) / [pr-driven-iac-lab](./pr-driven-iac-lab) / [cloud-agnostic-infra-lab](./cloud-agnostic-infra-lab) |

## 設計時に意識していること

プロジェクトの要件に応じて、次の点を取り入れています。

| 観点 | 実施内容 | 例 |
|---|---|---|
| 運用 | 構築後の動作確認、ログ調査、トラブルシューティング、削除手順まで用意 | [EKS Golden Node Pipeline](./eks-golden-node-pipeline) |
| セキュリティ | OIDCやIRSAによる一時認証、用途別のIAMロール、Private Subnet、暗号化、通信拒否テスト | [AWS Multilayer Firewall](./aws-multilayer-firewall-terraform) |
| コスト | Spot、Graviton、サーバーレス、予算監視、月額試算を構成に応じて採用 | [Bedrock AI Platform Sandbox](./bedrock-ai-platform-sandbox) |

GitHub ActionsからAWSへ接続する構成ではOIDCを使い、長期アクセスキーを置かないようにしています。外部公開が不要なワークロードはPrivate Subnetへ配置し、対応するAWSサービスでは保存データの暗号化を有効にしています。

## 検証範囲

プロジェクトごとに、実環境での動作確認、`terraform plan`、静的解析、設計検証のいずれかを実施しています。いずれも個人環境での検証であり、商用環境での運用実績を示すものではありません。

確認できる範囲で、構築手順、テスト方法、トラブルシューティング、コスト試算、削除手順を各READMEに記載しています。

## 使用技術

| 分野 | 主な技術 |
|---|---|
| Infrastructure as Code | Terraform, AWS CDK, Pulumi, CloudFormation |
| AWS | VPC, IAM, EKS, ECS, Lambda, S3, RDS/Aurora, DynamoDB, EventBridge, Step Functions, Bedrock |
| Security | Security Hub, AWS Config, WAF, Network Firewall, GuardDuty, KMS, OIDC, IRSA |
| Containers / Platform | Docker, Kubernetes, EKS, Karpenter, Argo CD, Istio, Crossplane |
| Configuration / Image | Ansible, Packer |
| CI/CD / Quality | GitHub Actions, TFLint, Checkov, pytest, Go test |
| Observability | CloudWatch, X-Ray, AMP, Grafana |

## プロジェクト一覧

分野ごとに各プロジェクトをまとめています。

<details>
<summary><strong>AI / Bedrock / MLOps</strong></summary>

- [bedrock-ai-platform-sandbox](./bedrock-ai-platform-sandbox) — セキュリティ、可観測性、予算管理を含む生成AI基盤
- [knowledge-bot](./knowledge-bot) — FastAPIとBedrock Knowledge Baseを使ったEKS上のRAGアプリ
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

- [aws-multilayer-firewall-terraform](./aws-multilayer-firewall-terraform) — NACL、Security Group、Network Firewall、WAFによる多層防御
- [security-hub-ai-triage](./security-hub-ai-triage) — Security Hub Findingのイベント駆動トリアージ
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

- [eks-golden-node-pipeline](./eks-golden-node-pipeline) — Golden AMIとKarpenterを使ったEKSノード管理
- [terraform-eks-production-platform](./terraform-eks-production-platform) — ネットワーク、EKS、配備、監視を含むプラットフォーム検証
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

- [terraform-handson](./terraform-handson) — AWS基本構成、module化、リモートState管理の段階的な検証
- [terraform-aws-iac-workflow](./terraform-aws-iac-workflow) — TerraformのIaCワークフロー
- [pr-driven-iac-lab](./pr-driven-iac-lab) — PRを起点としたTerraformワークフロー
- [iac-trilogy-lab](./iac-trilogy-lab) — Terraform、Pulumi、AWS CDKの比較
- [cloud-agnostic-infra-lab](./cloud-agnostic-infra-lab) — AWS、GCP、Azureの比較検証

</details>
