# ✅Phase 5: 比較・ADR完成・面接準備・クリーンアップ

## このフェーズの前提

Phase 1〜4がすべて完了していること：
- Atlantis on ECS Fargate でPR-drivenワークフローを体験済み
- Terraform Cloud でPR-drivenワークフローを体験済み
- 両方の運用を実際に手を動かして確認済み

## このフェーズの目的

- AtlantisとTFCの比較表を作成する
- ADRの Decision セクションを自分の言葉で完成させる
- STAR形式の面接回答を準備する
- Zenn記事のアウトラインを作成する
- リソースをクリーンアップしてコストを0にする

## タスク 5-1: 比較観察の整理

`docs/architecture.md` に以下の比較セクションを追加すること（**Takuya本人が記述**）：

```markdown
## Atlantis vs Terraform Cloud 比較

| 観点 | Atlantis | Terraform Cloud |
|------|----------|-----------------|
| ホスティング | | |
| セットアップ難易度 | | |
| IAM権限管理 | | |
| State管理 | | |
| ワークフローのトリガー | | |
| apply の承認フロー | | |
| 監査ログ | | |
| コスト | | |
| カスタマイズ性 | | |
| チーム向け機能 | | |
| 学習コスト | | |
| 自社導入のしやすさ | | |
```

各セルは体験に基づいて記述すること。AIによる補完禁止。

## タスク 5-2: ADR-001 の Decision セクション記述

`docs/adr/ADR-001-atlantis-vs-tfc.md` の以下のセクションを記述：

```markdown
## Decision

<!-- 以下をTakuya本人が記述。体験した上での判断理由を書くこと -->

## Consequences

<!-- 選択した場合の結果・影響を記述 -->
```

記述のヒント（AIが書いてはいけない。Takuya本人が体験から考える）：
- どちらを本番環境で使うとしたら？その理由は？
- チームの規模や技術力によって答えは変わるか？
- AWSのみの環境 vs マルチクラウドで答えは変わるか？
- 今の会社（または転職希望先）ならどちらが合うか？

## タスク 5-3: ADR-002 の Decision セクション記述

`docs/adr/ADR-002-atlantis-on-ecs.md` の以下のセクションを記述：

```markdown
## Decision

<!-- Atlantis のホスティング先に ECS Fargate を選んだ理由 -->
<!-- EC2やEKSではなくECSを選んだトレードオフ -->
<!-- FARGATE_SPOTにした理由とリスク -->
```

## タスク 5-4: runbook.md の作成

`docs/runbook.md` を作成。以下のセクションを含めること：

```markdown
# PR-driven IaC ワークフロー Runbook

## 1. 通常のTerraform変更フロー（Atlantis）

### ステップ
1. feature/* ブランチを作成
2. Terraform コードを変更
3. PRを main に向けて作成
4. Atlantis の plan コメントを確認
5. レビュアーに Approve を依頼
6. PR コメントに `atlantis apply` と入力
7. apply 完了を確認して PR を merge

### トラブルシューティング

#### Atlantisがplanコメントを投稿しない場合
- GitHub Webhook の Recent Deliveries を確認
- ECS タスクのログを確認: `aws logs tail /ecs/atlantis --follow`
- Atlantis ヘルスチェック: `curl http://{alb_dns}/healthz`

#### apply が `approved` 要件で拒否される場合
- PR にレビュアーの Approve が必要
- Settings > Branches の Branch protection rules を確認

#### State lock が解放されない場合
- DynamoDB の `tfstate-lock-pr-driven-iac-lab` テーブルを確認
- LockID を確認して手動削除:
  ```bash
  aws dynamodb delete-item \
    --table-name tfstate-lock-pr-driven-iac-lab \
    --key '{"LockID": {"S": "sample-infra/terraform.tfstate"}}' \
    --region ap-northeast-1
  ```

## 2. 通常のTerraform変更フロー（Terraform Cloud）

### ステップ
1. feature/* ブランチを作成
2. Terraform コードを変更
3. PRを main に向けて作成
4. GitHub Checks の TFC plan 結果を確認
5. TFC UI または GitHub でapplyを承認
6. PR を merge

## 3. Atlantis の再起動方法

```bash
# ECS タスクを強制的に新しいタスクに置き換え
aws ecs update-service \
  --cluster atlantis-cluster \
  --service atlantis \
  --force-new-deployment \
  --region ap-northeast-1
```

## 4. コスト削減のためのスケールダウン

```bash
# ラボ不使用時にAtlantisをスケールダウン
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
```

## タスク 5-5: STAR形式面接回答の作成

`interview/star-answers.md` を作成。以下の質問への回答を記述（Takuya本人が記述）：

---

### Q1: チームでのTerraform運用経験について教えてください

**Situation:**
```
（どんな状況・背景か。チーム規模、Terraformの使い方の現状）
```

**Task:**
```
（何を解決しようとしていたか。PR-driven導入の目的）
```

**Action:**
```
（具体的に何をしたか。Atlantis on ECS Fargateの構築、TFCの比較検証など）
```

**Result:**
```
（結果どうなったか。学べたこと、導入するとしたらどう変わるか）
```

---

### Q2: AtlantisとTerraform Cloudを比較した場合、どちらを選びますか？

```
（体験に基づいた自分の見解を記述。正解はない。理由が大事）
```

---

### Q3: Terraform のステートファイル管理でどんな工夫をしていますか？

```
（S3+DynamoDB vs TFC、リモートステートの重要性、ロックの仕組みなど）
```

---

### Q4: インフラ変更をチームでレビューする仕組みをどう設計しますか？

```
（PR-drivenの設計思想、apply_requirements、承認フロー、監査ログなど）
```

---

## タスク 5-6: Zenn記事アウトラインの作成

`docs/zenn-article-outline.md` を作成：

```markdown
# Zenn記事: AtlantisとTerraform Cloudで学ぶPR-driven IaC

## ターゲット読者
- Terraformは使っているが、チームワークフローを構築したことがない人
- AtlantisかTFCの導入を検討しているインフラエンジニア

## 記事構成案

### はじめに
- PR-driven IaCとは何か（1段落）
- なぜ `terraform apply` を手元で叩いてはいけないのか

### Atlantis編
- アーキテクチャ（Mermaid図）
- ECS Fargateへのデプロイのポイント
- atlantis.yamlの設計
- apply_requirementsの意味

### Terraform Cloud編
- VCS-drivenワークフローの設定
- ステートをTFCに移行した手順
- GitHub Environmentとの組み合わせ

### 比較表

### どちらを選ぶべきか

### おわりに・参考リンク
```

## タスク 5-7: リソースクリーンアップ（必須）

**このタスクは必ず実行すること。放置するとALB・ECS・VPC Interfaceエンドポイントのコストが発生する。**

### 順序が重要。以下の順番でdestroyすること：

```bash
# 1. sample-infra を先に destroy（atlantisが管理しているリソース）
cd terraform/sample-infra
terraform destroy -auto-approve

# 2. atlantis-infra を destroy
cd ../atlantis-infra
terraform destroy -auto-approve

# 3. bootstrap は最後（ステートバックエンドのため）
# bootstrap の S3 バケットを空にする
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3 rm s3://tfstate-pr-driven-iac-lab-${ACCOUNT_ID} --recursive

cd ../bootstrap
terraform destroy -auto-approve
```

### Terraform Cloud のクリーンアップ

```bash
# TFC Workspace の削除（UIから）
# 1. https://app.terraform.io でWorkspaceを選択
# 2. Settings > Destruction and Deletion
# 3. "Delete from Terraform Cloud" をクリック
```

### GitHub のクリーンアップ

```bash
# GitHub Webhookの削除（GitHub UIまたはCLI）
gh api repos/{owner}/pr-driven-iac-lab/hooks --jq '.[].id' | \
  xargs -I{} gh api -X DELETE repos/{owner}/pr-driven-iac-lab/hooks/{}
```

### クリーンアップ確認

```bash
# ECS クラスターが存在しないことを確認
aws ecs list-clusters --region ap-northeast-1

# ALB が存在しないことを確認  
aws elbv2 describe-load-balancers --region ap-northeast-1

# VPC が存在しないことを確認（atlantis-infra用）
aws ec2 describe-vpcs --region ap-northeast-1 \
  --filters "Name=tag:Project,Values=pr-driven-iac-lab"

# S3バケットが存在しないことを確認
aws s3 ls | grep pr-driven-iac-lab
```

## Phase 5 完了確認チェックリスト

- [ ] `docs/architecture.md` の比較表が埋まっている（Takuya記述）
- [ ] `docs/adr/ADR-001-atlantis-vs-tfc.md` の Decision セクションが記述済み
- [ ] `docs/adr/ADR-002-atlantis-on-ecs.md` の Decision セクションが記述済み
- [ ] `docs/runbook.md` が作成済み
- [ ] `interview/star-answers.md` の4問すべてに回答が記述済み
- [ ] `docs/zenn-article-outline.md` が作成済み
- [ ] `terraform destroy` が全ディレクトリで完了済み
- [ ] AWSコンソールでリソースが残っていないことを確認済み

## 最終口頭説明チェックポイント

15分間、ノートなしで話せること（面接シミュレーション）：

**テーマ: 「PR-driven IaCワークフローを実装・比較した経験について教えてください」**

含めるべき内容：
1. なぜPR-drivenが必要か（手元applyの問題点）
2. AtlantisとTFCそれぞれのアーキテクチャと実装の概要
3. 両者のトレードオフ（自分の体験に基づく）
4. どちらを推薦するか（理由付き）
5. チーム導入時に気をつけるべきこと

---

## おめでとうございます 🎉

このラボを完走した時点で：
- **PR-drivenワークフローの設計・実装経験**（Atlantis + TFC両方）
- **ECS Fargate への本番相当のサービスデプロイ経験**
- **Terraformのリモートステート・ロック・バックエンド移行経験**
- **GitHub Actions × OIDC / API認証の実装経験**

をポートフォリオとして語れる状態になっています。

次のステップ候補：
- Zenn記事の執筆・公開
- GitHubのREADMEにアーキテクチャ図とワークフロー説明を追加
- TFC の Dynamic Provider Credentials（OIDC）に挑戦