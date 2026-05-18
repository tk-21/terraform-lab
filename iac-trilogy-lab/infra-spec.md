# infra-spec.md — 共通インフラ仕様書

> この仕様書は3実装（Terraform / CDK / Pulumi）の「正解定義」。
> 実装ツールが変わっても、ここに書かれたインフラは同一でなければならない。

## 構成図

```
Internet
    │
    ▼
Internet Gateway (itl-dev-igw)
    │
    ▼
VPC: 10.10.0.0/16 (itl-dev-vpc)
    │
    ├── Public Subnet: 10.10.1.0/24 (itl-dev-public-1a)
    │       │
    │       ▼
    │   EC2: t4g.nano (itl-dev-app)
    │   ├── IMDSv2 強制
    │   ├── SSM Instance Profile
    │   └── SSH禁止（SG: アウトバウンドのみ）
    │
    └── S3: itl-dev-artifacts-{account_id}
            ├── バージョニング: ON
            └── パブリックアクセス: 全ブロック

監視:
├── AWS Budgets: $10/月 アラート (SNS → Email)
└── CloudWatch Alarm: CPU > 80% (SNS → Email)
```

## リソース一覧

| リソース | 識別子 | 値 |
|---|---|---|
| VPC | itl-dev-vpc | CIDR: 10.10.0.0/16 |
| Subnet | itl-dev-public-1a | CIDR: 10.10.1.0/24, AZ: ap-northeast-1a |
| IGW | itl-dev-igw | VPCにアタッチ |
| Route Table | itl-dev-public-rt | 0.0.0.0/0 → IGW |
| Security Group | itl-dev-app-sg | Egress: All開放, Ingress: なし |
| EC2 | itl-dev-app | t4g.nano, Amazon Linux 2023 arm64 |
| IAM Role | itl-dev-ec2-role | AmazonSSMManagedInstanceCore |
| S3 | itl-dev-artifacts-{account_id} | バージョニングON |
| Budget | itl-dev-monthly-budget | $10/月 |
| CloudWatch Alarm | itl-dev-cpu-alarm | CPU > 80% |

## タグ規則（全リソース必須）

```
Project   = iac-trilogy-lab
Env       = dev
ManagedBy = {terraform|cdk|pulumi}  ← フェーズごとに変える
CostOwner = takuya
```

## 検証完了条件

- [ ] EC2にSSM Session Managerで接続できる
- [ ] EC2からS3にファイルをアップロードできる（IAMロール経由）
- [ ] AWS Budgetsにアラートが設定されている
- [ ] CloudWatch Alarmが作成されている
- [ ] セキュリティグループにSSH(22)が含まれていない
- [ ] IMDSv2が強制されている（`curl http://169.254.169.254/latest/meta-data/` が401を返す）