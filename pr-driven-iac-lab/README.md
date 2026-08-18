# PR-driven IaC Lab

GitHub PR を起点に `terraform plan / apply` を実行する **PR-driven IaC ワークフロー**を、
Self-hosted（Atlantis on ECS Fargate）と SaaS（Terraform Cloud）の両方で実装・比較するハンズオンラボです。

---

## このハンズオンで得られること

### 技術スキル

| スキル | 具体的な内容 |
|---|---|
| **PR-driven IaC の設計** | PR open → plan コメント → approve → apply → merge の完全フローを手で動かす |
| **Atlantis の構築・運用** | ECS Fargate（arm64 + FARGATE_SPOT）への Self-hosted デプロイ、atlantis.yaml 設計 |
| **ECS Fargate 本番相当の設計** | NAT Gateway + VPC Endpoints、IAM Task Role 分離、Graviton2 最適化 |
| **Terraform State 管理** | S3 + DynamoDB によるリモートステート、TFC への移行（`-migrate-state`）、ロック機構の理解 |
| **IAM 最小権限設計** | Task Execution Role と Task Role の分離、wildcard 禁止の具体的な実装 |
| **GitHub Actions × TFC 連携** | `TF_API_TOKEN` 認証、GitHub Environment 承認ゲート、PRコメントへの plan 結果投稿 |
| **ADR の作成** | アーキテクチャ判断を記録する Architecture Decision Record を体験から書く |

### 面接で話せる経験値

このラボを完走すると、以下を**自分の体験として**語れるようになります：

- 「PR-driven IaCワークフローを AtlantisとTFC の両方で実装・比較しました」
- 「ECS Fargate に Self-hosted ツールをデプロイし、IAM 最小権限・VPC Endpoints でセキュアに構成しました」
- 「チームの terraform apply をPR経由に統制し、承認フロー・audit trail を整備する設計をしました」

### AtlantisとTFCのトレードオフを体感する

```
Atlantis（Self-hosted）           Terraform Cloud（SaaS）
───────────────────────────       ───────────────────────────
カスタマイズ性が高い               セットアップが早い
VPC内でplan/applyが完結            State管理・UIが付属
ECS/IAM/VPCの運用が必要           インフラ管理不要
コスト: ECS + ALB 実費             500リソースまで無料
```

どちらを本番で選ぶかを**自分の体験に基づいて判断できる**ことがゴールです。

---

## 前提条件

### ツール

```bash
# バージョン確認コマンド（すべて通ること）
terraform version       # >= 1.6.0
aws --version           # AWS CLI v2
gh --version            # GitHub CLI
git --version
```

### AWS 環境

```bash
# 認証確認（アカウントIDが表示されればOK）
aws sts get-caller-identity
```

- IAM ユーザーまたはロールに `AdministratorAccess` 相当の権限があること
- デフォルトリージョン: `ap-northeast-1`（東京）

### GitHub 環境

```bash
# 認証確認
gh auth status
```

- `pr-driven-iac-lab` という名前のリポジトリが作成済みであること
- ローカルにクローン済みであること

### Terraform Cloud（Phase 4 以降）

- [app.terraform.io](https://app.terraform.io/signup/account) でアカウント作成済みであること（無料）

---

## アーキテクチャ概要

```
┌────────────────────────────────────────────────────────────┐
│  このラボで扱うインフラ（3層構造）                           │
│                                                            │
│  Layer 3: sample-infra ←── AtlantisまたはTFCが管理する対象  │
│           S3バケット・IAMロール・IAMポリシー                 │
│                                                            │
│  Layer 2: atlantis-infra ←── Atlantis本体                  │
│           VPC・ALB・ECS Fargate（Atlantisコンテナ）         │
│                                                            │
│  Layer 1: bootstrap ←── Stateバックエンド（手動で1回だけ）   │
│           S3バケット・DynamoDBテーブル                       │
└────────────────────────────────────────────────────────────┘
```

詳細は [ARCHITECTURE.md](./ARCHITECTURE.md) を参照してください。

---

## フェーズ構成

| フェーズ | 内容 | 所要時間目安 |
|---|---|---|
| **Phase 1** | Stateバックエンド構築・sample-infra コード作成 | 1〜2時間 |
| **Phase 2** | Atlantis on ECS Fargate の構築 | 2〜3時間 |
| **Phase 3** | Atlantis PR-driven ワークフローの完全体験 | 1〜2時間 |
| **Phase 4** | Terraform Cloud ワークフローの実装・体験 | 1〜2時間 |
| **Phase 5** | 比較・ADR・クリーンアップ | 1時間 |

---

## Phase 1: Stateバックエンド構築

### 目的

Atlantis のリモートステートを管理する S3 + DynamoDB を構築します。
この「bootstrap」は**手動で1回だけ apply** します。以降の変更はすべて PR 経由になります。

### なぜ bootstrap を先に作るのか

```
通常の Terraform: stateファイルをどこかに置く必要がある
                           ↓
Terraformで S3 を作る → でもその state はどこに置く？ （鶏卵問題）
                           ↓
解決策: bootstrap だけ手動 apply でローカルstate → S3作成後にリモートへ移行
```

### 手順

**Step 1: bootstrap apply**

```bash
cd terraform/bootstrap

# AWSアカウントIDを確認
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${ACCOUNT_ID}"

terraform init
terraform plan -var="aws_account_id=${ACCOUNT_ID}"
terraform apply -var="aws_account_id=${ACCOUNT_ID}"
```

apply 完了後、出力に以下が表示されます：

```
Outputs:
s3_bucket_name     = "tfstate-pr-driven-iac-lab-123456789012"
dynamodb_table_name = "tfstate-lock-pr-driven-iac-lab"
```

**Step 2: atlantis-infra の backend.tf を更新**

```bash
# 出力されたバケット名で PLACEHOLDER を置き換える
BUCKET_NAME="tfstate-pr-driven-iac-lab-${ACCOUNT_ID}"

# terraform/atlantis-infra/backend.tf の PLACEHOLDER を実際のバケット名に変更
sed -i "s/tfstate-pr-driven-iac-lab-PLACEHOLDER/${BUCKET_NAME}/" \
  terraform/atlantis-infra/backend.tf

# 確認
cat terraform/atlantis-infra/backend.tf
```

**Step 3: atlantis-infra の初期化確認**

```bash
cd terraform/atlantis-infra
terraform init
terraform validate
```

エラーなく完了すれば Phase 1 完了です。

### Phase 1 完了チェック

```bash
# S3バケットの存在確認
aws s3 ls | grep pr-driven-iac-lab

# DynamoDBテーブルの確認
aws dynamodb describe-table \
  --table-name tfstate-lock-pr-driven-iac-lab \
  --region ap-northeast-1 \
  --query "Table.TableStatus"
```

- [ ] `s3://tfstate-pr-driven-iac-lab-{account_id}` が存在する
- [ ] DynamoDB テーブル `tfstate-lock-pr-driven-iac-lab` が `ACTIVE` 状態
- [ ] `terraform/atlantis-infra/backend.tf` の PLACEHOLDER が実際のバケット名に置き換わっている
- [ ] `terraform validate` がエラーなく完了する

---

## Phase 2: Atlantis on ECS Fargate 構築

### 目的

Atlantis を ECS Fargate（arm64 + FARGATE_SPOT）でホスティングし、
GitHub Webhook と接続します。AWS サービスへの通信は VPC Endpoints を優先し、
GHCR からのイメージ取得と GitHub への通信には NAT Gateway を使用します。

> **ネットワーク設計**: ECS タスクはプライベートサブネットに配置します。外部レジストリ `ghcr.io` のイメージ取得と GitHub API への通信にはインターネット到達性が必要なため、private route table のデフォルトルートは NAT Gateway を経由します。S3、DynamoDB、ECR、CloudWatch Logs、SSM への通信は既存の VPC Endpoints を利用します。

### Step 1: GitHub PAT と Webhook シークレットを SSM に保存

**GitHub PAT（Personal Access Token）の作成:**

GitHub > Settings > Developer settings > Personal access tokens > Fine-grained tokens

必要権限:
- `Contents`: Read and Write
- `Pull requests`: Read and Write
- `Webhooks`: Read and Write

```bash
# GitHub PAT を SSM に保存
aws ssm put-parameter \
  --name "/atlantis/github-token" \
  --value "ghp_xxxxxxxxxxxx" \
  --type "SecureString" \
  --region ap-northeast-1

# Webhook シークレット（ランダム生成）を SSM に保存
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Webhook Secret（後で使うのでメモ）: ${WEBHOOK_SECRET}"

aws ssm put-parameter \
  --name "/atlantis/webhook-secret" \
  --value "${WEBHOOK_SECRET}" \
  --type "SecureString" \
  --region ap-northeast-1
```

### Step 2: atlantis-infra apply

```bash
cd terraform/atlantis-infra

# Phase 1 で backend.tf の PLACEHOLDER を置き換え済みであることを確認
grep 'bucket.*tfstate-pr-driven-iac-lab-' backend.tf

terraform init

# GitHubユーザー名を指定して plan
terraform plan -var="github_repo_owner=あなたのGitHubユーザー名"

# apply（ALB・ECS・VPC等が作成される）
terraform apply -var="github_repo_owner=あなたのGitHubユーザー名"
```

apply 完了後の出力例：

```
Outputs:
alb_dns_name  = "atlantis-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com"
webhook_url   = "http://atlantis-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com/events"
atlantis_url  = "http://atlantis-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com"
```

### Step 3: Atlantis の動作確認

```bash
ALB_DNS="atlantis-alb-xxxxxxxxxx.ap-northeast-1.elb.amazonaws.com"  # 実際の値に変更

# ヘルスチェック（{"status":"ok"} が返れば起動成功）
curl "http://${ALB_DNS}/healthz"

# ECSタスクのログ確認
aws logs tail /ecs/atlantis --follow --region ap-northeast-1
```

> **ヒント**: ECS タスクが起動するまで 1〜2 分かかります。`{"status":"ok"}` が返るまで待ちましょう。
> `503 Service Temporarily Unavailable` の場合は、ALB に正常な ECS ターゲットが登録されていません。Step 3 のログと ECS サービスイベントを確認してください。

### Step 4: GitHub Webhook の設定

GitHub リポジトリ > Settings > Webhooks > Add webhook

| 項目 | 値 |
|---|---|
| Payload URL | `http://${ALB_DNS}/events` |
| Content type | `application/json` |
| Secret | Step 1 でメモした Webhook Secret |
| Events | `Pull requests`, `Issue comments`, `Push` |

設定後、Recent Deliveries タブに緑のチェックマークが表示されれば成功です。

### Phase 2 完了チェック

```bash
# ECSサービスの状態確認
aws ecs describe-services \
  --cluster atlantis-cluster \
  --services atlantis \
  --region ap-northeast-1 \
  --query "services[0].{Status:status,RunningCount:runningCount}"

# Atlantisヘルスチェック
curl "http://${ALB_DNS}/healthz"
```

- [ ] ECS タスクが `RUNNING` 状態
- [ ] `curl /healthz` が `{"status":"ok"}` を返す
- [ ] GitHub Webhook の Recent Deliveries が成功（緑チェック）
- [ ] NAT Gateway 経由で ECS タスクが GHCR イメージを取得できる

---

## Phase 3: Atlantis PR-driven ワークフロー体験

### 目的

PR open → plan → review → apply → merge の完全フローを実際に動かします。
3つのシナリオで Atlantis の動作パターンを確認します。

### Atlantis のフロー

```
1. feature/* ブランチで変更 → PR open
2. Atlantis が自動で terraform plan を実行
3. PR に plan 結果がコメントされる
4. PR の内容をレビュー（複数人運用ではレビュアーが Approve）
5. PR のコメントに「atlantis apply」と入力
6. Atlantis が terraform apply を実行
7. PR を merge
```

---

### シナリオ 1: 正常系（タグ追加）

```bash
git checkout main && git pull origin main
git checkout -b feature/add-cost-center-tag

# terraform/sample-infra/main.tf の S3バケットの tags に追加:
# CostCenter = "lab-001"

git add terraform/sample-infra/main.tf
git commit -m "feat: S3バケットにCostCenterタグを追加"
git push origin feature/add-cost-center-tag

gh pr create \
  --title "feat: S3バケットにCostCenterタグを追加" \
  --body "コスト管理のためプロジェクト識別タグを追加します。Atlantisがplanを自動実行します。"
```

**確認手順:**

1. PR 作成後 30 秒以内に Atlantis が plan コメントを投稿することを確認
2. `Plan: 0 to add, 1 to change, 0 to destroy` が含まれることを確認
3. PR の差分が想定どおりであることを確認（複数人運用ではレビュアーが **Approve**）
4. PR コメント欄に **`atlantis apply`** と入力
5. Atlantis が apply を実行し、結果コメントが投稿されることを確認
6. PR を **merge**

```bash
# apply後: タグが付いたか確認
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3api get-bucket-tagging \
  --bucket "sample-infra-dev-${ACCOUNT_ID}" \
  --region ap-northeast-1
```

---

### シナリオ 2: plan 失敗ケース（意図的な構文エラー）

```bash
git checkout -b feature/intentional-error

# terraform/sample-infra/main.tf の末尾に追加（意図的なエラー）:
cat >> terraform/sample-infra/main.tf << 'TFEOF'

resource "aws_s3_bucket" "this_will_fail" {
  # bucket パラメータなし（必須パラメータ欠如）
}
TFEOF

git add terraform/sample-infra/main.tf
git commit -m "test: plan失敗ケースの確認"
git push origin feature/intentional-error

gh pr create --title "test: plan失敗確認用（マージしない）" \
  --body "Atlantisのエラーハンドリング確認用。mergeしません。"
```

**確認ポイント:**
- Atlantis が PR にエラーコメントを投稿することを確認
- エラー内容が `Missing required argument` 等で読めることを確認

```bash
# 確認後クローズ
gh pr close $(gh pr list --head feature/intentional-error --json number -q '.[0].number')
git checkout main
git branch -D feature/intentional-error
```

---

### シナリオ 3: apply 要件未達（複数人運用での Approve なし apply 試行）

> 現在の学習用設定では、1人で apply を体験できるよう `approved` 要件を外しています。
> このシナリオを実行する場合は、先に `atlantis.yaml` の `apply_requirements` へ `- approved` を戻してください。

```bash
git checkout -b feature/no-approve-test

# 軽微な変更（タグ追加）を加えてPR作成
git add terraform/sample-infra/main.tf
git commit -m "test: approve未達確認"
git push origin feature/no-approve-test

gh pr create --title "test: Approve未達テスト" \
  --body "Approveせずに atlantis apply を試みます。"
```

PR をApprove**せずに**コメント欄に `atlantis apply` と入力し、
以下の拒否メッセージが表示されることを確認：

```
Apply requirement not met: approved
```

```bash
# 確認後クローズ
gh pr close $(gh pr list --head feature/no-approve-test --json number -q '.[0].number')
git checkout main
```

### Phase 3 完了チェック

- [ ] シナリオ 1: plan → review → `atlantis apply` → merge が完走した
- [ ] シナリオ 2: plan 失敗時に Atlantis のエラーコメントを確認した
- [ ] シナリオ 3: `approved` を有効化した場合に、Approve なしで apply が拒否されることを確認した
- [ ] CloudWatch Logs で webhook 受信〜plan コメント投稿の流れを追えた

---

## Phase 4: Terraform Cloud ワークフロー実装

### 目的

Terraform Cloud（TFC）を使って同じ sample-infra を管理し、Atlantis と比較します。
State 管理が S3 から TFC に移行される体験を含みます。

### Step 1: Terraform Cloud のセットアップ

**Organization と Workspace の作成:**

1. [app.terraform.io](https://app.terraform.io) にログイン
2. Organization を作成（例: `takuya-iac-lab`）
3. Workspace を作成:
   - Type: **Version Control Workflow**
   - Name: `sample-infra-dev`
   - VCS: GitHub > `pr-driven-iac-lab` リポジトリ
   - Terraform Working Directory: `terraform/sample-infra`
   - Auto Apply: **OFF**

**Workspace の AWS 認証情報を設定:**

TFC Workspace > Variables タブ > Add variable

```
環境変数（Sensitive にチェック）:
  AWS_ACCESS_KEY_ID     = （TFC専用IAMユーザーのアクセスキー）
  AWS_SECRET_ACCESS_KEY = （TFC専用IAMユーザーのシークレットキー）
  AWS_DEFAULT_REGION    = ap-northeast-1
```

> **TFC 専用 IAM ユーザーの作成（最小権限）:**
> ```bash
> aws iam create-user --user-name tfc-sample-infra-deployer
> # sample-infra が管理するリソースへの権限のみ付与
> # （Atlantis の Task Role と同等スコープ）
> aws iam create-access-key --user-name tfc-sample-infra-deployer
> ```

### Step 2: Terraform Cloud バックエンドを初期化

```bash
cd terraform/sample-infra

# backend.tf の organization は作成した TFC Organization 名と一致させる
# 必要に応じて backend.tf を編集してから実行する

# TFC にログイン（ブラウザが自動で開く）
terraform login

# 現在の backend.tf は Terraform Cloud 用の cloud ブロックを定義済み
terraform init
```

TFC UI > Workspace > States タブで State が管理されていることを確認してください。

> Phase 3 で sample-infra の State を S3 に作成している場合は、`terraform init -migrate-state` を実行して TFC へ移行します。

### Step 3: GitHub Secrets と Environment の設定

```bash
# TFC API Token を GitHub Secrets に登録
gh secret set TF_API_TOKEN \
  --body "$(cat ~/.terraform.d/credentials.tfrc.json | jq -r '.credentials["app.terraform.io"].token')"
```

**GitHub Environment（承認ゲート）の設定:**

GitHub > Settings > Environments > New environment

1. 名前: `production`
2. Required reviewers に自分のアカウントを追加
3. Save protection rules

### Step 4: VCS-driven ワークフローの体験

```bash
git checkout main && git pull origin main
git checkout -b feature/tfc-test-add-tag

# terraform/sample-infra/main.tf の S3バケットの tags に追加:
# TerraformBackend = "terraform-cloud"

git add terraform/sample-infra/main.tf
git commit -m "feat(tfc): TFCバックエンド識別タグを追加"
git push origin feature/tfc-test-add-tag

gh pr create \
  --title "feat: TFC動作確認 - タグ追加" \
  --body "TFCバックエンド移行後の初回PR-drivenテスト"
```

**確認ポイント:**

1. PR の Checks タブに `Terraform Cloud / sample-infra-dev` が出現する
2. [app.terraform.io](https://app.terraform.io) > Workspace > Runs でリモート plan を確認
3. PR をApprove して main に merge
4. `production` Environment の承認要求が届く → 承認
5. `terraform apply` が TFC 上でリモート実行される

### Phase 4 完了チェック

- [ ] TFC Organization と Workspace が作成済み
- [ ] PR 作成後に TFC が自動で plan を実行した
- [ ] TFC UI の Runs タブで実行履歴を確認した
- [ ] State が TFC UI の States タブで管理されている
- [ ] GitHub Secrets に `TF_API_TOKEN` が設定済み
- [ ] GitHub Environment `production` の承認ゲートが動作した
- [ ] Atlantis と比較した際の相違点を 5 つ以上メモしている

---

## Phase 5: 比較・ADR・クリーンアップ

### Step 1: 比較表を埋める（自分の言葉で）

`docs/architecture.md` の比較表を体験に基づいて記述してください。
**AI による補完禁止。自分の体験から書くことが面接で語れる武器になります。**

### Step 2: ADR を書く（自分の言葉で）

`docs/adr/ADR-001-atlantis-vs-tfc.md` と `docs/adr/ADR-002-atlantis-on-ecs.md` の
`## Decision` セクションを体験から記述してください。

### Step 3: リソースのクリーンアップ（必須）

**ALB・ECS・VPC Interface Endpoints は放置するとコストが発生します。必ず実行してください。**

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# 1. sample-infra を先に destroy（AtlantisまたはTFCが管理しているリソース）
cd terraform/sample-infra
terraform destroy -auto-approve

# 2. atlantis-infra を destroy
cd ../atlantis-infra
terraform destroy -var="github_repo_owner=あなたのGitHubユーザー名" -auto-approve

# 3. bootstrap の S3 バケットを空にしてから destroy
aws s3 rm s3://tfstate-pr-driven-iac-lab-${ACCOUNT_ID} --recursive
cd ../bootstrap
terraform destroy -var="aws_account_id=${ACCOUNT_ID}" -auto-approve
```

> **順番が重要**: sample-infra → atlantis-infra → bootstrap の順に destroy すること。
> 逆順だと State バックエンドが先に消えて destroy できなくなります。

**TFC のクリーンアップ:**

app.terraform.io > Workspace > Settings > Destruction and Deletion > "Delete from Terraform Cloud"

**クリーンアップ確認:**

```bash
# ECSクラスターが存在しないことを確認
aws ecs list-clusters --region ap-northeast-1

# ALBが存在しないことを確認
aws elbv2 describe-load-balancers --region ap-northeast-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'atlantis')]"

# S3バケットが存在しないことを確認
aws s3 ls | grep pr-driven-iac-lab
```

---

## ドキュメント一覧

| ファイル | 内容 |
|---|---|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | アーキテクチャ完全解説（ネットワーク・IAM・フロー図） |
| [docs/architecture.md](./docs/architecture.md) | フロー図・Atlantis vs TFC 比較表（自分で記入） |
| [docs/runbook.md](./docs/runbook.md) | 運用手順・トラブルシューティング |
| [docs/adr/ADR-001-atlantis-vs-tfc.md](./docs/adr/ADR-001-atlantis-vs-tfc.md) | ADR: AtlantisとTFCの選択 |
| [docs/adr/ADR-002-atlantis-on-ecs.md](./docs/adr/ADR-002-atlantis-on-ecs.md) | ADR: Atlantis on ECS Fargate の選択 |
| [docs/zenn-article-outline.md](./docs/zenn-article-outline.md) | Zenn 記事アウトライン |
| [interview/star-answers.md](./interview/star-answers.md) | STAR 形式面接回答テンプレート |
| [atlantis.yaml](./atlantis.yaml) | Atlantis プロジェクト定義 |

---

## トラブルシューティング早見表

| 症状 | 確認コマンド / 対処 |
|---|---|
| Atlantis が plan コメントを投稿しない | GitHub Webhook の Recent Deliveries を確認。ECS タスクのログ: `aws logs tail /ecs/atlantis --follow` |
| `curl /healthz` が 503 を返す | ALB に正常ターゲットがない状態。ECS タスクが `RUNNING` か確認: `aws ecs describe-services --cluster atlantis-cluster --services atlantis` |
| `CannotPullContainerError` | private route table が NAT Gateway を経由しているか確認。`ghcr.io` のイメージ取得には外部通信が必要 |
| `apply requirement not met: approved` | PR に Approve が付いているか確認 |
| `apply requirement not met: mergeable` | `atlantis-status-check.yml`（terraform fmt）が通過しているか確認 |
| State lock が解放されない | DynamoDB の lock アイテムを確認・手動削除（[runbook.md](./docs/runbook.md) 参照） |
| TFC plan が走らない | `TF_API_TOKEN` が GitHub Secrets に設定されているか確認 |
| TFC apply が承認待ちのまま | GitHub Environments > production のレビュアーが承認待ちか確認 |

詳細なトラブルシューティングは [docs/runbook.md](./docs/runbook.md) を参照してください。

---

## コスト目安

| フェーズ | 起動中のリソース | 月額概算 |
|---|---|---|
| Phase 1 | S3 + DynamoDB のみ | ほぼ無料 |
| Phase 2〜3 | ECS Fargate + ALB + VPC Endpoints + NAT Gateway | 約 $55/月 + NAT Gateway の時間・データ処理料金 |
| Phase 4 | 上記 + TFC | Phase 2〜3 と同額（TFC Free Tier） |

**ラボを使わない日はスケールダウンを推奨：**

```bash
# Atlantis を一時停止（ALBコスト以外をゼロに）
aws ecs update-service \
  --cluster atlantis-cluster \
  --service atlantis \
  --desired-count 0 \
  --region ap-northeast-1

# 再開時
aws ecs update-service \
  --cluster atlantis-cluster \
  --service atlantis \
  --desired-count 1 \
  --region ap-northeast-1
```
