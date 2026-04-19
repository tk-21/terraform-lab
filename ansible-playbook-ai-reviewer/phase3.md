# ✅Phase 3: GitHub Actions カスタムAction + サンプルワークフロー
# Ansible Playbook AI Reviewer
#
# 【Phase 1-2 完了済み内容】
# - Terraform: IAM・API Gateway (APIキー認証)・Lambda・SSM構築済み
# - Lambda実装:
#   * playbook_parser.py: YAML解析・危険パターン事前スキャン
#   * bedrock_reviewer.py: Bedrock Claude Sonnetレビュー
#   * review_validator.py: 6項目バリデーション
#   * github_commenter.py: PRコメント投稿（重複防止・ラベル付与）
#   * index.py: API Gatewayハンドラー
#
# 【このフェーズの目的】
# 1. カスタムGitHub Action: 他のリポジトリから再利用できるAction定義
# 2. サンプルワークフロー: Ansible PlaybookのPR時に自動レビューするデモ
# 3. Terraform CI/CD: Lambda・Terraformの自動デプロイ
#
# 【実行方法】
# claude < phase3.md
# ============================================================

以下のファイルを作成してください。

## 1. カスタムGitHub Action

### github_actions/ansible-ai-review/action.yml
```yaml
# 再利用可能なカスタムGitHub Action定義
# 他リポジトリのワークフローから uses: ./github_actions/ansible-ai-review で呼び出せる

name: 'Ansible Playbook AI Reviewer'
description: 'Amazon Bedrockを使ってAnsible PlaybookのAIレビューをPRコメントに投稿する'
author: 'infra-team'

inputs:
  api_endpoint:
    description: 'Reviewer APIのエンドポイントURL'
    required: true
  api_key:
    description: 'API GatewayのAPIキー'
    required: true
  api_secret:
    description: '追加認証シークレット'
    required: true
  github_token:
    description: 'GitHubトークン（PRコメント投稿用）'
    required: true
    default: ${{ github.token }}
  playbook_paths:
    description: 'レビュー対象PlaybookのGlobパターン（カンマ区切り）'
    required: false
    default: '**/*.yml,**/*.yaml'
  fail_on_critical:
    description: 'CRITICALな問題が検出された場合にワークフローを失敗させるか'
    required: false
    default: 'true'

outputs:
  review_status:
    description: 'レビュー結果ステータス (passed/failed/error)'
  issues_found:
    description: '検出された問題の総数'
  overall_score:
    description: '総合スコア (0-100)'

runs:
  using: 'composite'
  steps:
    - name: 変更されたPlaybookファイルを取得
      id: get-changed-files
      shell: bash
      run: |
        # PRで変更されたファイルのうちPlaybookに該当するもののみ取得
        # github.event.pull_request.number を使用
        # gh cli でPRの変更ファイル一覧を取得
        # playbook_pathsのGlobパターンでフィルタリング
        echo "changed_playbooks=..." >> $GITHUB_OUTPUT

    - name: 各Playbookをレビュー
      id: review
      shell: bash
      run: |
        # 変更されたPlaybookを1つずつAPIに送信
        # レスポンスからoveralL_scoreとrisk_levelを取得
        # fail_on_criticalがtrueかつCRITICAL問題がある場合は exit 1
        # 結果をGITHUB_OUTPUTに書き込み

      env:
        API_ENDPOINT: ${{ inputs.api_endpoint }}
        API_KEY: ${{ inputs.api_key }}
        API_SECRET: ${{ inputs.api_secret }}
        GH_TOKEN: ${{ inputs.github_token }}
        PR_NUMBER: ${{ github.event.pull_request.number }}
        REPO_OWNER: ${{ github.repository_owner }}
        REPO_NAME: ${{ github.event.repository.name }}
```

### github_actions/ansible-ai-review/README.md
```markdown
カスタムActionの使い方説明
- 必要なSecrets設定方法
- 使用例（最小構成 / フル構成）
- 出力値の使い方
```

## 2. サンプルワークフロー

### .github/workflows/example_ansible_review.yml
```yaml
# 使用例: Ansible PlaybookのPR時にAIレビューを実行するワークフロー
# このファイルをAnsible管理リポジトリの .github/workflows/ にコピーして使う

name: Ansible Playbook AI Review

on:
  pull_request:
    branches: [main]
    paths:
      - '**.yml'
      - '**.yaml'

permissions:
  contents: read
  pull-requests: write  # PRコメント投稿に必要

jobs:
  ai-review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Ansible Playbook AI Review
        uses: ./github_actions/ansible-ai-review
        with:
          api_endpoint: ${{ secrets.AI_REVIEWER_API_ENDPOINT }}
          api_key: ${{ secrets.AI_REVIEWER_API_KEY }}
          api_secret: ${{ secrets.AI_REVIEWER_API_SECRET }}
          github_token: ${{ secrets.GITHUB_TOKEN }}
          playbook_paths: 'playbooks/**/*.yml,roles/**/*.yml'
          fail_on_critical: 'true'

      - name: レビュー結果サマリー表示
        # if: always() でレビュー失敗時にも実行
        run: |
          echo "レビュースコア: ${{ steps.ai-review.outputs.overall_score }}/100"
          echo "検出問題数: ${{ steps.ai-review.outputs.issues_found }}"
          echo "ステータス: ${{ steps.ai-review.outputs.review_status }}"
```

## 3. デプロイワークフロー

### .github/workflows/deploy.yml
```yaml
# Terraform + Lambda のデプロイワークフロー

name: Deploy

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  pull-requests: write

env:
  TF_VERSION: '1.9.x'
  PYTHON_VERSION: '3.12'
  AWS_REGION: 'ap-northeast-1'

jobs:
  terraform:
    name: Terraform
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
      - name: Terraform Format
        run: terraform fmt -check -recursive terraform/
      - name: Terraform Init
        run: terraform init
        working-directory: terraform/environments/dev
      - name: Terraform Validate
        run: terraform validate
        working-directory: terraform/environments/dev
      - name: Terraform Plan
        if: github.event_name == 'pull_request'
        run: terraform plan -no-color
        working-directory: terraform/environments/dev
        # PRコメントにplan結果を投稿
      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve
        working-directory: terraform/environments/dev

  deploy-lambda:
    name: Deploy Lambda
    runs-on: ubuntu-latest
    needs: terraform
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ env.PYTHON_VERSION }}
      - name: Install dependencies & Package
        run: |
          pip install -r lambda/playbook_reviewer/requirements.txt \
            -t lambda/playbook_reviewer/ --platform manylinux2014_aarch64 \
            --only-binary=:all:
          cd lambda/playbook_reviewer
          zip -r ../../lambda_package.zip .
      - name: Deploy to Lambda
        run: |
          aws lambda update-function-code \
            --function-name ansible-ai-reviewer \
            --zip-file fileb://lambda_package.zip
          aws lambda wait function-updated \
            --function-name ansible-ai-reviewer
          aws lambda publish-version \
            --function-name ansible-ai-reviewer
```

## 完了確認

- [ ] action.ymlのinputs/outputsが全て定義されていること
- [ ] example_ansible_review.ymlでfail_on_criticalが機能するロジックになっていること
- [ ] deploy.ymlにアクセスキーが含まれていないこと（OIDC認証のみ）
- [ ] Lambdaパッケージングで `--platform manylinux2014_aarch64` が指定されていること（arm64対応）
- [ ] PRのplan結果がコメントとして投稿されること