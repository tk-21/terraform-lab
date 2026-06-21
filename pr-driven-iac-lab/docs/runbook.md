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

---

## 2. 通常のTerraform変更フロー（Terraform Cloud）

### ステップ
1. feature/* ブランチを作成
2. Terraform コードを変更
3. PRを main に向けて作成
4. GitHub Checks の TFC plan 結果（PRコメント）を確認
5. レビュアーに Approve を依頼
6. PR を main に merge
7. GitHub Actions が `push to main` で起動
8. `environment: production` の承認ゲートが発動 → **GitHub Environmentレビュアーが承認**
9. `terraform apply` が TFC 上でリモート実行される

### トラブルシューティング

#### PRコメントにplanが投稿されない場合
- `tfc-pr-workflow.yml` の `paths` フィルタ（`terraform/sample-infra/**`）に変更が含まれているか確認
- `TF_API_TOKEN` シークレットがリポジトリに設定されているか確認
- Actions タブでワークフローのエラーログを確認

#### apply 後 GitHub Environment で承認待ちになる場合
- リポジトリの Settings > Environments > production の Reviewers を確認
- Reviewers に自分または対象ユーザーを追加する

---

## 3. Atlantis の再起動方法

```bash
# ECS タスクを強制的に新しいタスクに置き換え
aws ecs update-service \
  --cluster atlantis-cluster \
  --service atlantis \
  --force-new-deployment \
  --region ap-northeast-1
```

---

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

---

## 5. Atlantis ログ確認

```bash
# リアルタイムログ確認
aws logs tail /ecs/atlantis --follow --region ap-northeast-1

# 直近1時間のログ
aws logs tail /ecs/atlantis \
  --since 1h \
  --region ap-northeast-1
```

---

## 6. Terraform plan の手動実行（デバッグ用）

```bash
cd terraform/sample-infra

# Atlantis が使う backend を確認
cat backend.tf

# ローカルで plan（Atlantis と同じバックエンドを参照）
terraform init
terraform plan
```
