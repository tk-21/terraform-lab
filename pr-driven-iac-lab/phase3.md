# ✅Phase 3: Atlantis PR-driven ワークフロー 完全体験

## このフェーズの前提

Phase 2が完了していること：
- Atlantis ECS Fargate が稼働中
- GitHub Webhook が設定済み
- テスト PR で plan コメントを確認済み

## このフェーズの目的

- Atlantis の完全なワークフロー（plan → approve → apply → merge）を体験
- `atlantis.yaml` の設定をチューニングする
- Atlantis のセキュリティ設定（allowed_repos, apply_requirements）を理解する
- 複数ディレクトリ対応の `atlantis.yaml` を完成させる

## Atlantis ワークフロー全体像

```
1. PR を feature/* ブランチから main に向けて作成
2. Atlantis が自動で terraform plan を実行
3. PR に plan 結果がコメントされる
4. レビュアーが PR を Approve
5. PR コメントで `atlantis apply` と入力
6. Atlantis が terraform apply を実行
7. apply 結果がコメントされる
8. PR を merge
```

## タスク 3-1: atlantis.yaml の完成版作成

プロジェクトルートの `atlantis.yaml` を以下の完成版に更新：

```yaml
version: 3
automerge: false
delete_source_branch_on_merge: false

# 並列実行の設定
# 同一ワークスペースへの同時実行を防ぐ（ステートファイル競合防止）
parallel_plan: false
parallel_apply: false

projects:
  - name: sample-infra-dev
    dir: terraform/sample-infra
    workspace: default
    terraform_version: v1.6.0
    autoplan:
      when_modified:
        - "*.tf"
        - "*.tfvars"
      enabled: true
    apply_requirements:
      - approved      # 1名以上のApproveが必要
      - mergeable     # コンフリクトなし、必須ステータスチェック通過
    workflow: default
```

日本語コメントを `atlantis.yaml` 内に追記：
- `automerge: false` にした理由
- `parallel_plan: false` にした理由
- `apply_requirements` の各項目の意味

## タスク 3-2: ワークフロー体験 シナリオ1「正常系」

### シナリオ: S3バケットにタグを追加する変更

```bash
# 作業ブランチ作成
git checkout main
git pull origin main
git checkout -b feature/add-s3-tag

# terraform/sample-infra/main.tf を編集
# S3バケットのtagsに以下を追加:
#   CostCenter = "lab-001"

git add terraform/sample-infra/main.tf
git commit -m "feat: S3バケットにCostCenterタグを追加

理由: コスト管理のためプロジェクト識別タグを付与する"

git push origin feature/add-s3-tag
gh pr create \
  --title "feat: S3バケットにCostCenterタグを追加" \
  --body "## 変更内容
S3バケットに \`CostCenter = \"lab-001\"\` タグを追加

## 理由
コスト配賦のためプロジェクト識別タグが必要

## Atlantis Plan
Atlantisが自動でplanを実行します。planコメントを確認後、approveしてください。"
```

### 確認ポイント

1. PR作成後30秒以内にAtlantisがplanコメントを投稿することを確認
2. planコメントに以下が含まれることを確認:
   - `Plan: 0 to add, 1 to change, 0 to destroy`（タグ変更のみ）
   - `terraform plan` の詳細出力
3. GitHub UIでPRをApproveする
4. PRのコメント欄に `atlantis apply` と入力
5. Atlantisがapplyを実行し、結果をコメントすることを確認

```bash
# apply後の確認
aws s3api get-bucket-tagging \
  --bucket "sample-infra-dev-$(aws sts get-caller-identity --query Account --output text)" \
  --region ap-northeast-1
```

## タスク 3-3: ワークフロー体験 シナリオ2「plan失敗ケース」

### シナリオ: 意図的に Terraform の構文エラーを混入させる

```bash
git checkout -b feature/intentional-error

# terraform/sample-infra/main.tf の末尾に以下を追加（意図的な構文エラー）:
# resource "aws_s3_bucket" "this_will_fail" {
#   # bucketパラメータなし（必須パラメータ欠如）
# }

git add terraform/sample-infra/main.tf
git commit -m "test: plan失敗ケースの確認（意図的なエラー）"
git push origin feature/intentional-error
gh pr create --title "test: plan失敗確認用（マージしない）" --body "Atlantisのエラーハンドリング確認用PR"
```

### 確認ポイント

1. AtlantisがPRにエラーコメントを投稿することを確認
2. エラーの内容が読めるかを確認
3. PRを**mergeせずに**クローズする

```bash
gh pr close {PR番号}
git checkout main
git branch -D feature/intentional-error
```

## タスク 3-4: ワークフロー体験 シナリオ3「apply要件未達」

### シナリオ: Approve なしで apply を試みる

```bash
git checkout -b feature/no-approve-test

# タグを1つ変更するだけの無害なPR
git add terraform/sample-infra/main.tf
git commit -m "test: approve未達でapplyできないことを確認"
git push origin feature/no-approve-test
gh pr create --title "test: approve未達テスト" --body "Approveせずにatlantis applyを試みます"
```

PRのコメント欄に `atlantis apply` と入力し、Atlantisが拒否することを確認。
期待レスポンス: `Apply requirement not met: approved`

クローズして後始末：
```bash
gh pr close {PR番号}
```

## タスク 3-5: Atlantis ログの確認と理解

```bash
# ECSタスクのCloudWatch Logsを確認
aws logs tail /ecs/atlantis \
  --follow \
  --format short \
  --region ap-northeast-1
```

以下のログエントリを見つけて理解すること：
- Webhookを受信したログ
- `terraform plan` を実行したログ
- GitHubへのコメント投稿ログ

## タスク 3-6: Atlantis の設定を深掘り

`atlantis.yaml` に以下のカスタムワークフローを追加：

```yaml
workflows:
  default:
    plan:
      steps:
        - init:
            extra_args: ["-upgrade"]
        - plan:
            extra_args: ["-compact-warnings"]
    apply:
      steps:
        - apply:
            extra_args: ["-compact-warnings"]
```

変更後、PR を作成して plan が動くことを確認。

## タスク 3-7: GitHub Actions との連携確認（オプション）

`.github/workflows/atlantis-status-check.yml` を作成：

```yaml
name: Terraform Lint

on:
  pull_request:
    paths:
      - 'terraform/**'

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.6.0
      
      - name: Terraform Format Check
        run: |
          cd terraform/sample-infra
          terraform fmt -check -recursive
        # フォーマットエラーは apply を防ぐガードとして機能
        # atlantis.yaml の apply_requirements: mergeable と組み合わせて動作
```

このワークフローを `mergeable` 要件の必須ステータスチェックとして設定することで、
フォーマットエラーがある PR を apply できなくなる仕組みを体験する。

## Phase 3 完了確認チェックリスト

- [ ] シナリオ1: タグ追加 → plan確認 → approve → apply → merge が完走した
- [ ] シナリオ2: plan失敗時のAtlantisコメントを確認した
- [ ] シナリオ3: approve未達でapplyが拒否されることを確認した
- [ ] CloudWatch Logsでwebhook受信〜planコメント投稿の流れを追えた
- [ ] `atlantis.yaml` のカスタムワークフロー設定が動作している

## 口頭説明チェックポイント（Phase 3終了後）

以下を15分間、ノートなしで説明できること：

1. **AtlantisのPR-drivenフロー詳細**
   - webhook → plan → コメント → apply → merge の各ステップで何が起きているか
   - `apply_requirements: approved` と `mergeable` の違いと組み合わせの意味

2. **Atlantis の運用上の注意点**
   - `parallel_plan: false` が必要な理由（ステートロック競合）
   - 誰でも `atlantis apply` できてしまう問題とその対策
   - Atlantisの `--repo-allowlist` の重要性（セキュリティ）

3. **チームへの導入時に想定される課題**
   - 複数人が同じdirに触るPRが同時に存在した場合
   - Atlantisが落ちていた場合のフローへの影響
   - apply権限をどうコントロールするか