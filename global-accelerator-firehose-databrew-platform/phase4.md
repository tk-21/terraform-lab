# ✅Phase 4: オブザーバビリティ・CI/CD・README整備

## このフェーズの概要（Phase 1〜3 の続き）

Phase 1〜3 で以下が動作している前提：
- Global Accelerator → ALB → Lambda Receiver → Firehose → S3 Raw（データ蓄積中）
- DataBrew Job がスケジュール実行され S3 Processed に Parquet を出力している
- Athena でクエリ実行可能な状態

このフェーズで作成するもの：
- CloudWatch Dashboard（全体監視）
- CloudWatch Alarm（異常検知）
- GitHub Actions CI/CD パイプライン（OIDC認証）
- outputs.tf の完成
- README.md（ポートフォリオ品質）

---

## タスク一覧

### 1. CloudWatch Dashboard + Alarm

`terraform/modules/observability/main.tf` を作成する。

```
# [1] CloudWatch Dashboard
# resource: aws_cloudwatch_dashboard
# dashboard_name: "${var.name_prefix}-dashboard"
#
# ウィジェット構成:
#
# 行1タイトル: "Global Accelerator & ALB"（テキストウィジェット）
#
# 行1左: Global Accelerator メトリクス
#   - NewFlowCount: 新規TCP/UDPフロー数（エッジへの接続数の代理指標）
#   - ProcessedByteCount: 処理バイト数
#   namespace: "AWS/GlobalAccelerator"
#   # 日本語コメント: Global AcceleratorのメトリクスはリージョンではなくUS East (N. Virginia)
#   # でのみ利用可能なため region="us-east-1" を明示する
#
# 行1右: ALB メトリクス
#   - RequestCount: リクエスト数
#   - HTTPCode_Target_5XX_Count: バックエンドエラー数（赤色）
#   - TargetResponseTime（P99）: レイテンシ99パーセンタイル
#   namespace: "AWS/ApplicationELB"
#
# 行2タイトル: "Lambda & Kinesis Firehose"
#
# 行2左: Lambda Receiver メトリクス
#   - Invocations, Errors, Duration(P99)
#
# 行2中央: Lambda Generator メトリクス
#   - Invocations, Errors
#
# 行2右: Kinesis Firehose メトリクス
#   - IncomingRecords: 受信レコード数
#   - DeliveryToS3.Records: S3配信成功レコード数
#   - DeliveryToS3.DataFreshness: データ鮮度（秒）
#   # 日本語コメント: DataFreshness はFirehoseバッファの最大滞留時間
#   # 60秒設定なので通常は60秒以下になる
#
# 行3タイトル: "DataBrew & Data Lake"
#
# 行3: DataBrew ジョブメトリクス（CloudWatch Logsインサイトベース）
#   - 直近5回のジョブ実行成功/失敗をログクエリで可視化
#   # 日本語コメント: DataBrewはCloudWatch Metricsを直接出さないため
#   # Logsインサイトクエリウィジェットで代替する

# [2] CloudWatch Alarm（Firehose配信エラー）
# resource: aws_cloudwatch_metric_alarm
# alarm_name: "${var.name_prefix}-firehose-delivery-error"
# namespace: "AWS/Firehose"
# metric_name: "DeliveryToS3.Success"
# comparison_operator: "LessThanThreshold"
# threshold: 1
# evaluation_periods: 3
# period: 300
# statistic: "Sum"
# alarm_description: "Firehoseのデータ配信が停止しています"
# treat_missing_data: "breaching"
# # 日本語コメント: 15分間（3×5分）S3配信が0件なら異常とみなす

# [3] CloudWatch Alarm（ALB 5xxエラー急増）
# resource: aws_cloudwatch_metric_alarm
# alarm_name: "${var.name_prefix}-alb-5xx-spike"
# namespace: "AWS/ApplicationELB"
# metric_name: "HTTPCode_Target_5XX_Count"
# threshold: 10
# evaluation_periods: 2
# period: 60
# alarm_description: "ALBバックエンドエラーが急増しています"
# # 日本語コメント: 1分間に10件以上の5xxエラーが2回連続したら異常
```

---

### 2. GitHub Actions CI/CD パイプライン

`.github/workflows/terraform.yml` を作成する。

```yaml
# パイプライン概要:
#   - PR時: terraform fmt check → validate → plan（結果をPRコメントに投稿）
#   - mainへのpush時: terraform fmt → validate（applyは手動実行）
#
# 環境変数:
#   TF_VERSION: "1.6.6"
#   AWS_REGION: "ap-northeast-1"
#
# permissions:
#   id-token: write    # OIDC必須
#   contents: read
#   pull-requests: write
#
# jobs:
#
# [1] terraform-ci（全トリガーで実行）
#   runs-on: ubuntu-latest
#   steps:
#     - uses: actions/checkout@v4
#     - uses: aws-actions/configure-aws-credentials@v4
#       with:
#         role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
#         aws-region: ${{ env.AWS_REGION }}
#       # 日本語コメント: OIDCでIAMロールを引き受けて一時クレデンシャルを取得
#       # シークレットにアクセスキーを保存しないことがセキュリティ上のベストプラクティス
#     - uses: hashicorp/setup-terraform@v3
#       with:
#         terraform_version: ${{ env.TF_VERSION }}
#     - name: Terraform Format Check
#       run: terraform -chdir=terraform fmt -check -recursive
#     - name: Terraform Init（バックエンドなし）
#       run: terraform -chdir=terraform init -backend=false
#     - name: Terraform Validate
#       run: terraform -chdir=terraform validate
#
# [2] terraform-plan（PRのみ）
#   needs: terraform-ci
#   if: github.event_name == 'pull_request'
#   steps:
#     - (checkout + credentials + setup は同様)
#     - name: Terraform Init（バックエンドあり）
#       run: |
#         terraform -chdir=terraform init \
#           -backend-config="bucket=${{ secrets.TF_STATE_BUCKET }}" \
#           -backend-config="key=gaf/terraform.tfstate" \
#           -backend-config="region=ap-northeast-1"
#     - name: Terraform Plan
#       id: plan
#       run: |
#         terraform -chdir=terraform plan \
#           -var="aws_account_id=${{ secrets.AWS_ACCOUNT_ID }}" \
#           -no-color 2>&1 | tee plan_output.txt
#     - name: Post Plan to PR
#       uses: actions/github-script@v7
#       with:
#         script: |
#           const fs = require('fs');
#           const plan = fs.readFileSync('plan_output.txt', 'utf8');
#           const truncated = plan.length > 60000 ? plan.slice(0, 60000) + '\n...(truncated)' : plan;
#           github.rest.issues.createComment({
#             issue_number: context.issue.number,
#             owner: context.repo.owner,
#             repo: context.repo.repo,
#             body: `## Terraform Plan\n\`\`\`\n${truncated}\n\`\`\``
#           });
```

---

### 3. outputs.tf の完成

`terraform/outputs.tf` に全フェーズ分のoutputを集約する。

```hcl
# 出力すべき値（全モジュールのkeyアウトプットを集約）:
#
# ネットワーク:
# - vpc_id
# - public_subnet_ids（リスト）
# - private_subnet_ids（リスト）
#
# Global Accelerator:
# - accelerator_dns_name（"https://${dns}" でGenerator環境変数に設定）
# - accelerator_static_ips（静的IPアドレス2つ）
# - accelerator_arn
#
# ALB:
# - alb_dns_name
# - alb_arn
#
# Firehose:
# - firehose_stream_name
# - firehose_stream_arn
#
# S3:
# - raw_bucket_name
# - processed_bucket_name
# - athena_results_bucket_name
#
# DataBrew:
# - databrew_job_name
# - databrew_project_name
#
# Glue / Athena:
# - glue_database_name
# - athena_workgroup_name
#
# 便利URL（マネコンへの直リンク）:
# - cloudwatch_dashboard_url:
#     "https://ap-northeast-1.console.aws.amazon.com/cloudwatch/home?region=ap-northeast-1#dashboards:name=${var.name_prefix}-dashboard"
# - athena_workgroup_url:
#     "https://ap-northeast-1.console.aws.amazon.com/athena/home?region=ap-northeast-1#/workgroups"
```

---

### 4. README.md の作成（ポートフォリオ品質）

`README.md` を以下の構成で日本語メインで作成すること。

```markdown
# global-accelerator-firehose-databrew-platform

> グローバルトラフィック最適化 × リアルタイムデータ取り込み × ノーコードETL Data Lake
> AWS Global Accelerator × Kinesis Data Firehose × Glue DataBrew × Athena on Terraform

## アーキテクチャ図（Mermaid）

flowchart LR
  subgraph Generator["Lambda Generator\n(arm64, EventBridge 3min)"]
    G[ダミーリクエスト\n50件/回]
  end
  subgraph GA["AWS Global Accelerator"]
    E[静的Anycast IP × 2\nエッジ最適ルーティング]
  end
  subgraph ALB["ALB (ap-northeast-1)"]
    L[Lambda Target Group\nHTTP/HTTPS Listener]
  end
  subgraph Receiver["Lambda Receiver (arm64)"]
    R[HTTPログ構造化\nJSON生成]
  end
  subgraph Firehose["Kinesis Data Firehose"]
    F[バッファリング\n60秒 or 5MB]
  end
  subgraph DataLake["S3 Data Lake"]
    RAW[Raw NDJSON\nyear/month/day/hour]
    PROC[Processed Parquet\n+ latency_category\n+ is_error]
  end
  subgraph ETL["Glue DataBrew"]
    DB[Recipe 6ステップ\nノーコードETL]
  end
  subgraph Query["Athena + Glue Catalog"]
    A[SQL クエリ\nParquetスキャン]
  end

  G -->|HTTPS| E --> L --> R --> F --> RAW
  RAW --> DB --> PROC --> A

## 主要コンポーネントの解説

### AWS Global Accelerator
- **静的Anycast IP**: グローバルに2つの固定IPを提供
- **AWSバックボーンネットワーク**: パブリックインターネットを経由せず低レイテンシを実現
- **ヘルスチェック**: ALBが応答しなくなった場合の自動フェイルオーバー
- **フローログ**: エッジロケーション別のトラフィック分析が可能

### Kinesis Data Firehose
- Lambda から直接S3に書くより**小ファイル問題を解消**
- バッファリング（60秒）でS3書き込みを最適化
- 配信失敗時のエラーレコード自動保存

### Glue DataBrew
- コード不要の240種以上の変換組み込み
- **TerraformでRecipeをIaC化** → 環境間の再現性を保証
- `latency_category`・`is_error` カラムを自動付与

## Getting Started

### Prerequisites
- Terraform >= 1.6
- AWS CLI v2
- Python 3.12（Lambdaビルド用）

### Deploy

\`\`\`bash
# 1. Lambdaパッケージをビルド
bash scripts/build_lambda.sh

# 2. インフラをデプロイ
cd terraform
terraform init
terraform apply -var="aws_account_id=YOUR_ACCOUNT_ID"

# 3. DataBrewジョブを手動実行（最初のデータ変換）
bash scripts/run_databrew_job.sh
\`\`\`

### Verify

\`\`\`bash
# Global Accelerator の静的IPを確認
terraform output accelerator_static_ips

# S3 Rawにデータが蓄積されているか確認（Firehoseバッファ後 = 約1〜2分）
aws s3 ls s3://$(terraform output -raw raw_bucket_name)/logs/ --recursive | head -20

# Athena でクエリ実行
aws athena start-query-execution \
  --query-string "SELECT path, COUNT(*) as cnt FROM gaf_db.processed_logs GROUP BY path" \
  --work-group gaf-dev-workgroup \
  --region ap-northeast-1
\`\`\`

## Cost Estimate & Cleanup

| サービス | 月額概算 |
|---|---|
| Global Accelerator | ~$18（固定 + 転送量） |
| ALB | ~$16（最低料金） |
| Lambda × 2 | < $1 |
| Kinesis Firehose | < $1 |
| Glue DataBrew | < $2 |
| S3 × 3 | < $1 |
| **合計** | **~$38/月** |

⚠️ **ハンズオン後は必ず Destroy してください**

\`\`\`bash
cd terraform && terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
\`\`\`

## Architecture Decisions

[Phase 3で追記したDataBrew採用理由を再掲]

## 学習ポイント

1. **Global Accelerator vs CloudFront**: 静的コンテンツキャッシュではなく TCP/UDP最適化が目的
2. **Firehose バッファ戦略**: 小ファイル問題・コスト・鮮度のトレードオフ
3. **DataBrew Recipe の IaC化**: ノーコードをコードで再現する価値
4. **Athena パーティション**: Hive形式プレフィックスでスキャンコスト削減
```

---

## 完了条件

- [ ] CloudWatch Dashboard で全サービスのメトリクスが表示される
- [ ] GitHub Actions の OIDC が設定され、PR で terraform plan が自動実行される
- [ ] `terraform output` で全主要リソース情報が確認できる
- [ ] README.md に Mermaid アーキテクチャ図が含まれる
- [ ] `terraform destroy` で全リソースが削除される（S3バケットの force_destroy=true を確認）
- [ ] Global Accelerator の課金が停止することを AWS Billing で確認