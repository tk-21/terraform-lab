# ecs-chaos-lab — Claude Code プロジェクトガイド

## プロジェクト概要

AWS FIS (Fault Injection Simulator) × ECS Fargate によるカオスエンジニアリング基盤。
3種類の障害シナリオを Terraform で完全 IaC 化し、ECS Service の回復性を自動検証する。

**ポートフォリオ訴求ポイント**:
- FIS ECS 実験テンプレートの Terraform IaC 化（再現性・バージョン管理）
- Task Kill / Network Disruption / Desired Count 0 の3シナリオを網羅
- Fargate + ALB 構成での自己回復性（Service Auto Recovery）の可視化

---

## ディレクトリ構造

```
ecs-chaos-lab/
├── CLAUDE.md                            # このファイル（Claude Code 自動ロード）
├── README.md
├── terraform/
│   ├── environments/
│   │   └── dev/
│   │       ├── main.tf
│   │       ├── variables.tf
│   │       ├── outputs.tf
│   │       ├── locals.tf
│   │       ├── versions.tf
│   │       └── terraform.tfvars
│   └── modules/
│       ├── vpc/          # VPC / サブネット / IGW / NAT(1AZ)
│       ├── sg/           # ALB SG / ECS Task SG
│       ├── ecr/          # ECR リポジトリ + ライフサイクルポリシー
│       ├── ecs/          # ECS Cluster / Task Definition / Service
│       ├── alb/          # ALB / Target Group / Listener
│       ├── iam/          # FIS 実行ロール / ECS Task 実行ロール / Task ロール
│       └── fis/          # 3種類の FIS 実験テンプレート
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
├── app/
│   ├── Dockerfile        # ヘルスチェック付きサンプル nginx
│   └── html/
│       └── index.html
├── scripts/
│   ├── bootstrap.sh      # ECR へのイメージ初回プッシュ
│   ├── run_task_kill.sh          # シナリオ1実行
│   ├── run_network_disruption.sh # シナリオ2実行
│   ├── run_desired_zero.sh       # シナリオ3実行
│   └── watch_service.sh          # ECS Service 状態リアルタイム監視
├── docs/
│   └── adrs/
│       ├── 001-fargate-over-ec2.md
│       ├── 002-three-scenario-design.md
│       └── 003-network-disruption-mechanism.md
└── runbooks/
    ├── scenario1-task-kill.md
    ├── scenario2-network-disruption.md
    └── scenario3-desired-zero.md
```

---

## 技術スタック・制約

| 項目 | 値 |
|------|-----|
| リージョン | ap-northeast-1 (Tokyo) |
| Terraform バージョン | >= 1.9 |
| AWS プロバイダー | ~> 5.0 |
| ECS 起動タイプ | FARGATE |
| コンテナイメージ | nginx:alpine（ECR にプッシュして使用）|
| 通知 | Chatwork |
| 認証 | OIDC (GitHub Actions) |

---

## 命名規則

- リソースプレフィックス: `ecl` (ecs-chaos-lab)
- 例: `ecl-dev-cluster`, `ecl-dev-service`, `ecl-fis-task-kill-role`
- IAM ロール名は 64 文字以内
- タグ必須:
  ```
  Project    = "ecs-chaos-lab"
  Env        = "dev"
  ManagedBy  = "terraform"
  ```

---

## 3シナリオの設計概要

### シナリオ 1: Task 強制停止（aws:ecs:task-kill）

```
FIS 実験開始
  ↓
対象: ecl-dev-service の Task を 100% 強制停止
  ↓
観測: ECS Service が desired_count(2) を維持しようと新 Task を起動
  ↓
合格基準: 2分以内に RunningCount = 2 に復帰
  ↓
停止条件: CloudWatch RunningTaskCount < 1 が 5 分継続（安全弁）
```

**FIS アクション**: `aws:ecs:task-kill`
- `cluster`: ecl-dev-cluster
- `service`: ecl-dev-service
- `taskArn` フィルタ: 全 Task（PERCENT(100)）

---

### シナリオ 2: ネットワーク遮断（aws:ecs:task-network-blackhole-port）

```
FIS 実験開始
  ↓
対象: ecl-dev-service の Task の インバウンド TCP:80 を遮断
  ↓
観測: ALB ヘルスチェックが失敗 → Target が Unhealthy → ALB が503
  ↓
FIS 終了後: ネットワーク復旧 → ALB が再び Healthy を検知
  ↓
停止条件: HealthyHostCount = 0 が 3 分継続（全断防止）
```

**FIS アクション**: `aws:ecs:task-network-blackhole-port`
- `trafficType`: ingress
- `port`: 80
- `protocol`: tcp
- `duration`: PT3M（3分）

> ⚠️ ネットワーク遮断は Fargate の場合 `aws:ecs:task-network-blackhole-port` を使用。
> EC2 の `aws:network:disrupt-connectivity` とは異なるアクション ID。

---

### シナリオ 3: Desired Count 0 → 復旧確認

```
FIS 実験開始
  ↓
対象: ecl-dev-service の DesiredCount を 0 に変更
  ↓
観測: 全 Task が Stopped → ALB が 503
  ↓
FIS 終了後: DesiredCount を 2 に復元（手動 or EventBridge 自動化）
  ↓
合格基準: 3分以内に RunningCount = 2 かつ ALB Healthy
  ↓
停止条件: なし（DesiredCount=0 は安全な状態のため）
```

**FIS アクション**: `aws:ecs:update-cluster-settings` または
`aws:ecs:update-service-desired-count`（カスタム SSM ドキュメント経由）

> 注: FIS ネイティブで DesiredCount 変更は非対応のため、
> Lambda を FIS アクションとして呼び出す設計（aws:lambda:invoke）を採用。

---

## ECS アーキテクチャ

```
Internet
  ↓
ALB (ecl-dev-alb) — public subnet × 2
  ↓ HTTP:80
Target Group (ecl-dev-tg)
  ↓
ECS Service (ecl-dev-service)
  Cluster: ecl-dev-cluster
  Task Definition: ecl-dev-task
  desired_count: 2
  launch_type: FARGATE
  network_mode: awsvpc        ← FIS ネットワーク遮断に必要
  assign_public_ip: DISABLED  ← private subnet 配置
  ↓
ECR (ecl-dev-nginx) — nginx:alpine イメージ
```

---

## IAM ロール設計

### FIS 実行ロール (`ecl-fis-execution-role`, 64文字以内)
```
ecs:StopTask                    # シナリオ1
ecs:DescribeTasks
ecs:ListTasks
ecs:UpdateService               # シナリオ3
ecs:DescribeServices
ec2:DescribeNetworkInterfaces   # シナリオ2（ネットワーク遮断対象を特定）
elasticloadbalancing:Describe*  # 停止条件のヘルスチェック確認
cloudwatch:DescribeAlarms       # 停止条件監視
logs:CreateLogGroup
logs:CreateLogStream
logs:PutLogEvents
lambda:InvokeFunction           # シナリオ3（Lambda 経由 DesiredCount 変更）
```

### ECS Task 実行ロール (`ecl-ecs-task-exec-role`)
```
AmazonECSTaskExecutionRolePolicy（マネージド）
```

### ECS Task ロール (`ecl-ecs-task-role`)
```
logs:CreateLogStream
logs:PutLogEvents
```

---

## Terraform モジュール依存関係

```
vpc → sg → alb
vpc → sg → ecs → iam（task_exec_role, task_role）
vpc → sg → ecr
fis → iam（fis_role）, ecs（cluster_arn, service_name）, alb（target_group_arn）
```

---

## コスト見積もり（月額）

| リソース | 概算 |
|----------|------|
| Fargate Task 0.25vCPU×0.5GB × 2 | ~$8 |
| ALB | ~$20 |
| NAT Gateway (1AZ) | ~$35 |
| ECR ストレージ | ~$1 |
| FIS 実験（従量） | ~$1 |
| **合計** | **~$65** |

> ⚠️ 検証後は `terraform destroy` 推奨。NAT GW が最大コスト。

---

## フェーズ実行順序

```
phase1.md → VPC / SG / ECR / ALB（ネットワーク基盤）
phase2.md → IAM / ECS Cluster / Task Definition / Service
phase3.md → FIS 3シナリオ実験テンプレート + Lambda（シナリオ3用）
phase4.md → 検証スクリプト + ADR × 3 + Runbook × 3 + README
```

実行コマンド:
```bash
claude < phase1.md
claude < phase2.md
claude < phase3.md
claude < phase4.md
```

---

## ポートフォリオ訴求ポイント（README / Zenn 用）

1. **FIS ECS ネイティブアクション**を Terraform で IaC 化（`aws:ecs:task-kill` / `aws:ecs:task-network-blackhole-port`）
2. **3シナリオ**で ECS Service の異なる障害パターンを網羅
3. **awsvpc ネットワークモード**を活用したタスクレベルのネットワーク遮断
4. Lambda を FIS アクションとして組み込んだ**カスタム障害注入**（シナリオ3）
5. **多層安全弁**: FIS 停止条件 + CloudWatch アラーム + IAM 最小権限