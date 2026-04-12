# Kubernetes デプロイ運用ランブック

対象: EKS 上の `knowledgebot` Deployment  
想定読者: アプリ担当者、運用担当者

## デプロイ手順

1. アプリイメージをビルドして ECR に push する
2. `APP_IMAGE` に対象タグを指定して `make deploy` を実行する
3. `kubectl -n knowledgebot rollout status deploy/knowledgebot` でロールアウト完了を確認する

## 推奨コマンド

```bash
./scripts/build_push_ecr.sh deploy-20260413
APP_IMAGE="<account>.dkr.ecr.ap-northeast-1.amazonaws.com/knowledge-bot/app:deploy-20260413" make deploy
kubectl -n knowledgebot rollout status deploy/knowledgebot
```

## 確認ポイント

- `kubectl -n knowledgebot get deploy,svc,ingress,pods`
- `kubectl -n knowledgebot get configmap knowledgebot-config -o yaml`
- `kubectl -n knowledgebot get deploy knowledgebot -o jsonpath='{.spec.template.spec.containers[0].image}'`

## よくある失敗

- `:dev` タグを上書きしても変更が反映されない
  - 毎回ユニークタグを使う
  - `APP_IMAGE=... make deploy` で明示的に反映する
- `RAG_MODE` が想定と違う
  - `knowledgebot-config` の `RAG_MODE` を確認する
- Pod は起動しているが UI の表示が古い
  - ブラウザを強制リロードする

## ロールバック

1. 直前に動いていたイメージタグを確認
2. そのタグを `APP_IMAGE` に指定して再度 `make deploy`
3. `rollout status` が成功することを確認
