# Bedrock モデル利用トラブルシュート

対象: MVP / KB モードの回答生成  
想定読者: アプリ担当者、権限設定担当者

## よくある失敗

### `use case details` 未完了

- Anthropic モデル利用時に発生しやすい
- Bedrock コンソールの `Model access` / `Model catalog` で確認する

### `Legacy` モデル指定

- 長期間未使用後に再利用できない場合がある
- `Active` なモデル ID へ切り替える

### Sonnet 4 の on-demand 非対応

- `anthropic.claude-sonnet-4-20250514-v1:0` をそのまま呼ぶと失敗することがある
- `global.anthropic.claude-sonnet-4-20250514-v1:0` のような inference profile ID を使う

### AWS Marketplace 権限不足

- 初回有効化では `aws-marketplace:Subscribe` などが必要になる場合がある
- アプリ用 IRSA ロールに Marketplace 権限を付与する

## 確認ポイント

- `kubectl -n knowledgebot get configmap knowledgebot-config -o yaml`
- `BEDROCK_MODEL_ID`
- `RAG_MODE`
- `KNOWLEDGE_BASE_ID`

## 対処の基本順序

1. 使うモデルが `Active` か確認
2. Anthropic の `use case details` を確認
3. Sonnet 4 系なら inference profile ID を使う
4. Marketplace 権限不足なら IRSA を更新
5. 再デプロイして ConfigMap と Pod の反映を確認
