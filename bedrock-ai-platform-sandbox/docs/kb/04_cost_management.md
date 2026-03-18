# コスト管理ガイド

## コスト構造の全体像

このプラットフォームのコストは「**固定費（インフラ維持費）**」と「**変動費（AI 利用費）**」に分かれる。

```
月額コスト
├── 固定費（常時発生）
│   ├── NAT Gateway:               ~$4.5/月（$0.062/h × 720h）
│   ├── Interface VPC Endpoint × 2: ~$14/月（$0.01/h × 2AZ × 2 × 720h）
│   └── WAF v2 WebACL:             ~$8/月（$5 + $1 × 3ルール）
│
└── 変動費（使用量に応じて変動）
    ├── Aurora Serverless v2:       $0〜$87/月（0.5〜4.0 ACU × $0.12/ACU-h）
    ├── Bedrock API（Claude Haiku）: $0.00025/1K input tokens
    ├── Bedrock API（Claude Sonnet）:$0.003/1K input tokens
    ├── Titan Embeddings V2:        $0.00002/1K tokens（知識ベース同期時）
    ├── Lambda:                     実質 $0（無料枠内）
    ├── DynamoDB:                   実質 $0（PAY_PER_REQUEST、少量）
    ├── S3:                         ~$0.5/月
    └── CloudWatch:                 ~$3.3/月（Dashboard + Alarms）
```

**月額 $30 の予算内に収めるポイント**: Aurora を不使用時に停止する。

---

## 月次コストの確認方法

### AWS Cost Explorer で実費を確認

```bash
# 当月のサービス別コスト（前日まで）
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --group-by Type=DIMENSION,Key=SERVICE \
  --region us-east-1 \
  --query "ResultsByTime[0].Groups[?Metrics.UnblendedCost.Amount > \`0.01\`].{Service:Keys[0], Cost:Metrics.UnblendedCost.Amount}" \
  --output table
```

### タグでプロジェクト別コストを分離

全リソースに `Project: bedrock-ai-platform-sandbox` タグが付与されているため、Cost Explorer でフィルタできる。

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d) \
  --granularity MONTHLY \
  --metrics "UnblendedCost" \
  --filter '{
    "Tags": {
      "Key": "Project",
      "Values": ["bedrock-ai-platform-sandbox"]
    }
  }' \
  --region us-east-1
```

---

## Bedrock API のコスト計算

Claude モデルの料金（ap-northeast-1 リージョン、2024年時点）:

| モデル | 入力トークン | 出力トークン |
|-------|------------|------------|
| Claude 3 Haiku | $0.00025 / 1K | $0.00125 / 1K |
| Claude 3.5 Sonnet v2 | $0.003 / 1K | $0.015 / 1K |
| Titan Embeddings V2 | $0.00002 / 1K | （出力なし） |

### 月次利用コスト試算

1日あたりの利用量の目安（dev 環境・個人利用）:

| シナリオ | Haiku 呼び出し | Sonnet 呼び出し | 推定日額 |
|--------|-------------|--------------|--------|
| 軽い検証 | 20回（各500トークン） | 5回（各1000トークン） | ~$0.02 |
| 中程度の検証 | 50回（各500トークン） | 20回（各2000トークン） | ~$0.17 |
| 重い検証 | 100回（各1000トークン） | 50回（各3000トークン） | ~$0.70 |

月間（30日）で重い検証を毎日行っても: ~$21 → 月額 $30 の範囲内。

### トークン使用量の確認

```bash
TODAY=$(date +%Y%m%d)

# 全テナントの本日の使用量
aws dynamodb scan \
  --table-name bedrock-ai-platform-sandbox-dev-usage \
  --filter-expression "#d = :today" \
  --expression-attribute-names '{"#d": "date"}' \
  --expression-attribute-values '{":today": {"S": "'"$TODAY"'"}}' \
  --region ap-northeast-1 \
  --query "Items[].{Tenant:tenant_id.S, Total:total_tokens.N, Input:input_tokens.N, Output:output_tokens.N}" \
  --output table
```

---

## Aurora のコスト管理（最重要）

Aurora Serverless v2 は **起動中は ACU 分の料金が発生し続ける**。

### ACU と料金の関係

| 状態 | ACU | 時間料金 | 月額（720時間） |
|-----|-----|---------|--------------|
| 最小（アイドル） | 0.5 ACU | $0.06/h | ~$43 |
| 中程度の負荷 | 2.0 ACU | $0.24/h | ~$173 |
| 最大（高負荷） | 4.0 ACU | $0.48/h | ~$346 |

> **重要**: Aurora は **停止しない限り最低 0.5 ACU の料金が継続的に発生**する。
> dev 環境では使用後に必ず停止するか、`terraform destroy` で削除すること。

### コスト最適化設定（現行）

```hcl
# modules/knowledge-base/main.tf
serverlessv2_scaling_configuration {
  min_capacity = 0.5   # 最小 ACU（コスト優先）
  max_capacity = 4.0   # 最大 ACU
}
```

アイドル時の ACU をさらに抑えたい場合: `min_capacity = 0` は Aurora Serverless v2 では非対応（最小は 0.5）。
代替として: 使用しないときに `stop-db-cluster` を実行する（7日経過で自動再起動される点に注意）。

---

## テナント別コスト管理

### トークン上限の役割

DynamoDB の usage テーブルで日次トークン使用量を記録し、`token_limit_daily` を超えると API が 429 を返す。これにより、特定テナントの使い過ぎを防ぐ。

### テナントごとの月次コスト推定

```
月次コスト（テナント単位） ≈
  （月間 input_tokens / 1000） × モデル単価_input
  +（月間 output_tokens / 1000） × モデル単価_output
```

DynamoDB で月次集計を行う場合:

```bash
# 当月のテナント別使用量合計（簡易版: 過去30日分のスキャン）
aws dynamodb scan \
  --table-name bedrock-ai-platform-sandbox-dev-usage \
  --region ap-northeast-1 \
  --query "Items[].{Tenant:tenant_id.S, Date:date.S, Total:total_tokens.N}" \
  --output table
```

### コスト超過時のフロー

```
Cost Controller Lambda（1時間ごとに実行）
        │
        ▼
全テナントの当日使用量を DynamoDB からスキャン
        │
        ├─ 日次上限の 80% 超過 → SNS: 警告メール送信
        │
        └─ 日次上限超過 → router-lambda が 429 を返す（自動制御）

AWS Budgets
        │
        ├─ 月額 $30 の 80% 到達 → SNS: 予算警告メール
        └─ 月額 $30 の 100% 到達 → SNS: 予算超過メール
```

---

## コスト削減施策チェックリスト

### 即効性あり（設定変更のみ）

- [ ] Aurora を不使用時に停止する（`aws rds stop-db-cluster`）→ **最大削減効果**
- [ ] Knowledge Base の同期は必要なときだけ実行する（Titan Embeddings の料金削減）
- [ ] Sonnet の使用頻度を抑える（ルーティング閾値の調整）

### Terraform 変更が必要

- [ ] Interface VPC Endpoint を 1 AZ に減らす（2AZ → 1AZ で ~$7/月削減、冗長性は失われる）
- [ ] CloudWatch Dashboard のウィジェット数を削減（$0.10/月/ウィジェット × 21 = ~$2.1/月）
- [ ] Aurora の `max_capacity` を 2.0 に下げる（高負荷時のコスト上限を下げる）

### 使用方針の変更

- [ ] ドキュメント同期は週1回にまとめる（Embeddings コスト削減）
- [ ] テスト時は Haiku のみを使用する（`preferred_model = "haiku"` をテナントに設定）
- [ ] 不要なテナントは削除する（使用量の誤集計を防ぐ）

---

## 予算アラートの設定確認

AWS Budgets のアラート設定を確認・更新する。

```bash
# 設定済みの Budgets を確認
aws budgets describe-budgets \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --region us-east-1 \
  --query "Budgets[].{Name:BudgetName, Limit:BudgetLimit.Amount, Currency:BudgetLimit.Unit}"
```

SNS のメール通知が届いていない場合: SNS サブスクリプションの確認メールが承認されていない可能性がある。

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn <ALERT_TOPIC_ARN> \
  --region ap-northeast-1 \
  --query "Subscriptions[].{Protocol:Protocol, Endpoint:Endpoint, Status:SubscriptionArn}"
```

`PendingConfirmation` のまま → 登録メールアドレスに届いた確認メールから承認する。
