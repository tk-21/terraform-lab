# Troubleshooting Retrospective

このドキュメントは、Knowledge Bot の構築・動作確認中に実際につまずいたポイントを整理した振り返りメモです。
運用手順の補足、今後の再現防止、発表時の説明材料として使うことを想定しています。

## 1. Terraform apply が長時間終わらない

### 症状

- `terraform apply` 実行中に以下のような表示が長時間続いた
- `module.eks.data.aws_iam_session_context.current[0]: Still reading...`
- `data.aws_iam_role.sso_admin[0]: Still reading...`

### 原因

- 初回は `sso_admin_role_arn` の設定や EKS module 側を疑ったが、最終的にはネットワーク不調が主因だった
- AWS SSO / IAM 参照が不安定になると、Terraform の data source が待ち続ける形で見えやすい

### 切り分けで分かったこと

- `sso_admin_role_arn` の形式は `assumed-role` ではなく `arn:aws:iam::...:role/...` が必要
- ただし今回はそこが本丸ではなく、ネットワーク不調の解消後は apply が進んだ

### 対処

- AWS 認証状態とネットワーク到達性を先に確認する
- `aws sso login`
- `aws sts get-caller-identity`

### 再発防止

- Terraform の data source 停滞はコード不備だけでなく、認証やネットワーク不調でも起きる前提で切り分ける
- relative な表示だけで判断せず、まず STS と IAM の疎通確認を行う

## 2. Ingress の URL を開いても画面が出ない

### 症状

- `kubectl get ingress` で URL は見えるが、ブラウザからアクセスしても表示されない

### 原因

- `k8s/base/ingress.yaml` が `alb.ingress.kubernetes.io/scheme: internal` になっていた
- そのため ALB は VPC 内向けで、手元のブラウザから直接見えない構成だった

### 対処

- `kubectl -n knowledgebot port-forward svc/knowledgebot 8080:80`
- `http://localhost:8080/`
- `http://localhost:8080/healthz`

### 再発防止

- `internal` ALB を使う場合、README に「Ingress 直アクセスは必須ではない」ことを明記する
- 本番確認は `rollout status` と `port-forward` を含めて書く

## 3. MVP モードで何を聞いても「根拠となるナレッジが見つからない」と返る

### 症状

- MVP モードで質問しても、ヒットなしメッセージばかり返る

### 原因

- 当初の MVP 実装は `app/src/main.py` のダミーチャンク 3 件だけを検索対象にしていた
- しかも検索が非常に単純な単語一致で、日本語の自然文に弱かった
- `docs/sample_knowledge/` の内容は MVP では見ていなかった

### 対処

- MVP モードでも `docs/sample_knowledge/*.md` をローカル読み込みするように変更
- 見出し単位で簡易チャンク化
- `rag_mvp.py` を、日本語の質問でも当たりやすい簡易検索へ改善

### 再発防止

- 「MVP だからダミーで十分」とせず、最低限デモ文書を直接検索できる形にする
- テストチェックリストは実装と同じ前提にそろえる

## 4. EKS に再デプロイしてもアプリ変更が反映されない

### 症状

- 修正後に `make build-push` と `make deploy` を実行しても、挙動が変わらない

### 原因

- 既定の `make build-push` は `:dev` タグを push する
- Deployment でも同じ `:dev` を使い続けると、Pod が新しいイメージを取り直さない場合がある

### 対処

- 毎回ユニークタグで ECR に push する
- `APP_IMAGE=... make deploy` でそのタグを明示して再デプロイする

### 再発防止

- 確認環境では `:dev` の上書き運用に頼らない
- 再デプロイ後は以下を必ず確認する
- `kubectl -n knowledgebot rollout status deploy/knowledgebot`
- `kubectl -n knowledgebot get deploy knowledgebot -o jsonpath='{.spec.template.spec.containers[0].image}'`

## 5. Bedrock モデル利用設定が未完了

### 症状

- `モデル利用設定が未完了です。Bedrockの利用申請状態を確認してください。`

### 原因

- Anthropic モデル利用に必要な `use case details` が未提出、または利用可能化が未完了

### 対処

- AWS コンソールの `Amazon Bedrock` で確認
- `Model access`
- `Model catalog`
- Anthropic モデルの有効化状態と `use case details` 提出状況を確認

### 再発防止

- モデル切り替え前に、コンソールでそのモデルが利用可能か確認する

## 6. Legacy モデルを指定してしまった

### 症状

- `This Model is marked by provider as Legacy ... Please upgrade to an active model`

### 原因

- `anthropic.claude-3-5-sonnet-20240620-v1:0` が `Legacy` 扱いで、長期間未使用後の再利用がブロックされた

### 対処

- `Active` なモデルへ切り替える
- Sonnet 4 系へ移行した

### 再発防止

- README に「Active モデルを使うこと」を明記する
- Bedrock の `Model access` / `Model catalog` で状態を確認する

## 7. Claude Sonnet 4 を model ID で直指定すると失敗する

### 症状

- `Invocation of model ID ... with on-demand throughput isn’t supported`

### 原因

- Claude Sonnet 4 系は、通常の model ID ではなく inference profile ID の利用が必要だった

### 対処

- `BEDROCK_MODEL_ID` を以下に変更
- `global.anthropic.claude-sonnet-4-20250514-v1:0`

### 再発防止

- Sonnet 4 系は inference profile を使うことを README と既定値に反映する

## 8. AWS Marketplace 権限不足でモデル有効化に失敗する

### 症状

- `Model access is denied due to IAM user or service role is not authorized to perform the required AWS Marketplace actions`

### 原因

- Bedrock Marketplace モデルの初回有効化で必要な権限が IRSA ロールに無かった

### 対処

- `infra/irsa_app.tf` に以下を追加
- `aws-marketplace:Subscribe`
- `aws-marketplace:Unsubscribe`
- `aws-marketplace:ViewSubscriptions`
- Terraform apply 後、少し待ってから再デプロイ

### 再発防止

- Bedrock Marketplace モデルを使う前提なら、初回有効化に必要な権限も最初から IaC に含める

## 9. MVP / KB の切り替え手順が README で分かりにくい

### 症状

- `RAG_MODE` の切り替え手順は断片的にあるが、実際の再デプロイと確認方法が追いにくかった

### 対処

- README に `MVP` / `KB` 切り替え手順を明示追加
- `ConfigMap` での確認ポイントも追記

## 学びの要約

- つまずきは「コード不具合」だけでなく、「ネットワーク」「認証」「Bedrock の利用条件」「Kubernetes の反映方式」に分散していた
- 特に Bedrock は「モデルがある」だけでは足りず、`Active/Legacy`、`inference profile`、`Marketplace 権限`、`use case details` まで確認が必要だった
- README に運用時の判断材料を追記したことで、次回は切り分けと再デプロイの速度を上げられる見込み
