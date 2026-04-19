# Ansible Playbook AI Reviewer Action

Amazon Bedrock (Claude Sonnet) を使って Ansible Playbook を自動レビューし、PRコメントとして投稿するカスタムGitHub Action。

## 必要なSecrets設定

リポジトリの **Settings > Secrets and variables > Actions** に以下を登録してください。

| Secret名 | 説明 | 取得方法 |
|---|---|---|
| `AI_REVIEWER_API_ENDPOINT` | API GatewayのエンドポイントURL | Terraform outputの `api_endpoint` |
| `AI_REVIEWER_API_KEY` | API GatewayのAPIキー | AWSコンソール or `aws apigateway get-api-keys` |
| `AI_REVIEWER_API_SECRET` | 追加認証シークレット | SSMパラメータ `/ansible-ai-reviewer/api-secret` |

`GITHUB_TOKEN` はGitHub Actionsが自動提供するため、別途設定不要です。

## 最小構成

```yaml
- name: Ansible Playbook AI Review
  uses: your-org/ansible-playbook-ai-reviewer/github_actions/ansible-ai-review@main
  with:
    api_endpoint: ${{ secrets.AI_REVIEWER_API_ENDPOINT }}
    api_key: ${{ secrets.AI_REVIEWER_API_KEY }}
    api_secret: ${{ secrets.AI_REVIEWER_API_SECRET }}
```

## フル構成

```yaml
- name: Ansible Playbook AI Review
  id: ai-review
  uses: your-org/ansible-playbook-ai-reviewer/github_actions/ansible-ai-review@main
  with:
    api_endpoint: ${{ secrets.AI_REVIEWER_API_ENDPOINT }}
    api_key: ${{ secrets.AI_REVIEWER_API_KEY }}
    api_secret: ${{ secrets.AI_REVIEWER_API_SECRET }}
    github_token: ${{ secrets.GITHUB_TOKEN }}
    playbook_paths: 'playbooks/**/*.yml,roles/**/*.yml'
    fail_on_critical: 'true'

- name: レビュー結果を確認
  if: always()
  run: |
    echo "スコア: ${{ steps.ai-review.outputs.overall_score }}/100"
    echo "問題数: ${{ steps.ai-review.outputs.issues_found }}"
    echo "ステータス: ${{ steps.ai-review.outputs.review_status }}"
```

## inputs

| パラメータ | 必須 | デフォルト | 説明 |
|---|---|---|---|
| `api_endpoint` | ✅ | - | Reviewer APIのエンドポイントURL |
| `api_key` | ✅ | - | API GatewayのAPIキー |
| `api_secret` | ✅ | - | 追加認証シークレット |
| `github_token` | ✅ | `${{ github.token }}` | PRコメント投稿用トークン |
| `playbook_paths` | ❌ | `**/*.yml,**/*.yaml` | レビュー対象のGlobパターン（カンマ区切り） |
| `fail_on_critical` | ❌ | `true` | CRITICAL検出時にワークフローを失敗させるか |

## outputs

| 出力名 | 説明 | 例 |
|---|---|---|
| `review_status` | レビュー結果ステータス | `passed` / `failed` / `error` |
| `issues_found` | 検出された問題の総数 | `3` |
| `overall_score` | 総合スコア (0-100) | `72` |

## ステータスの意味

| ステータス | 意味 |
|---|---|
| `passed` | 問題なし、またはCRITICAL未検出 |
| `failed` | CRITICAL問題が検出され、`fail_on_critical: true` が設定されている |
| `error` | APIへの接続エラーなど、レビュー処理自体が失敗 |

## 権限設定

ワークフロー側で以下のpermissionsが必要です。

```yaml
permissions:
  contents: read
  pull-requests: write  # PRコメント投稿に必要
```
