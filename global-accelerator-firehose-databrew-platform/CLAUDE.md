# global-accelerator-firehose-databrew-platform

## プロジェクト概要

AWS Global Accelerator × ALB × Kinesis Data Firehose × AWS Glue DataBrew を組み合わせた
グローバルトラフィック制御 + リアルタイムデータ取り込み + ノーコードETL基盤のTerraformハンズオン。

Lambda がダミーのHTTPリクエストログを生成し、Global Accelerator → ALB → Lambda Receiver で受け取り、
Kinesis Data Firehose 経由でS3に蓄積。Glue DataBrew がノーコードETLでデータクレンジング・変換し、
Athena でクエリ可能なData Lakeを構築する。

---

## ディレクトリ構造

```
global-accelerator-firehose-databrew-platform/
├── CLAUDE.md
├── README.md
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── locals.tf
│   └── modules/
│       ├── networking/            # VPC・サブネット・SG
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── global_accelerator/    # Global Accelerator・Listener・Endpoint Group
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── alb/                   # Application Load Balancer・Target Group
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── lambda_receiver/       # HTTPログ受信Lambda
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── src/
│       │       └── receiver.py
│       ├── lambda_generator/      # ダミーリクエスト生成Lambda
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   ├── outputs.tf
│       │   └── src/
│       │       └── generator.py
│       ├── firehose/              # Kinesis Data Firehose配信ストリーム
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── s3/                    # Raw/Processed/Athena結果バケット
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── databrew/              # Glue DataBrewプロジェクト・レシピ・ジョブ
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── glue/                  # Glue Data Catalog・Athena Workgroup
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── observability/        # CloudWatch Dashboard・Alarm
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
└── scripts/
    ├── build_lambda.sh            # Lambda依存ライブラリのビルド
    └── run_databrew_job.sh        # DataBrewジョブ手動実行
```

---

## 命名規則

| リソース種別 | 命名パターン | 例 |
|---|---|---|
| VPC | `{project}-vpc` | `gaf-vpc` |
| Global Accelerator | `{project}-accelerator` | `gaf-accelerator` |
| ALB | `{project}-alb` | `gaf-alb` |
| Lambda（受信） | `{project}-receiver` | `gaf-receiver` |
| Lambda（生成） | `{project}-generator` | `gaf-generator` |
| Firehose Stream | `{project}-delivery-stream` | `gaf-delivery-stream` |
| S3 Raw | `{project}-raw-{account_id}` | `gaf-raw-123456789012` |
| S3 Processed | `{project}-processed-{account_id}` | `gaf-processed-123456789012` |
| DataBrew Project | `{project}-databrew-project` | `gaf-databrew-project` |
| DataBrew Recipe | `{project}-recipe` | `gaf-recipe` |
| DataBrew Job | `{project}-job` | `gaf-job` |
| Glue Database | `{project}_db` | `gaf_db` |
| IAM Role | `{project}-{service}-role` | `gaf-firehose-role` |

**project短縮名**: `gaf`（global-accelerator-firehose）

---

## タグ戦略

```hcl
locals {
  common_tags = {
    Project     = "global-accelerator-firehose-databrew-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    CostCenter  = "portfolio"
  }
}
```

---

## アーキテクチャ概要

```
[Lambda Generator]
  ↓ EventBridge Scheduler（3分おき）
  ↓ HTTPS リクエスト（複数リージョン想定のダミー）
[Global Accelerator]
  ↓ エッジ最適化ルーティング（静的Anycast IP × 2）
[ALB]（ap-northeast-1）
  ↓ Target Group → Lambda Receiver
[Lambda Receiver]
  ↓ アクセスログをJSON構造化 → Kinesis Data Firehose に PUT
[Kinesis Data Firehose]
  ↓ バッファリング（60秒 or 5MB）→ S3 Raw バケット
  ↓ パス: s3://gaf-raw/logs/year=YYYY/month=MM/day=DD/hour=HH/
[Glue DataBrew Job]（スケジュール実行）
  ↓ ノーコードETL: 型変換・null除去・カラム追加（latency_category）
  ↓ 出力: s3://gaf-processed/ （Parquet + Snappy）
[Glue Data Catalog + Athena]
  ↓ SQLクエリでアクセスログ分析
```

---

## データスキーマ

### Raw ログ（Firehose → S3、NDJSON形式）

```json
{
  "request_id": "uuid4",
  "timestamp": "ISO8601",
  "source_ip": "xxx.xxx.xxx.xxx（ダミー）",
  "source_region": "us-east-1 | eu-west-1 | ap-northeast-1 | ap-southeast-1",
  "method": "GET | POST | PUT | DELETE",
  "path": "/api/users | /api/products | /api/orders | /health",
  "status_code": 200 | 201 | 400 | 404 | 500 | 503,
  "latency_ms": 10-2000,
  "user_agent": "Mozilla/5.0... | curl/... | python-requests/...",
  "accelerator_ip": "固定のダミーIP",
  "edge_location": "NRT | IAD | DUB | SIN"
}
```

### Processed データ（DataBrew変換後、Parquet形式）

上記に加えて DataBrew が付与するカラム：
- `latency_category`: "fast"(<100ms) | "normal"(100-500ms) | "slow"(>500ms)
- `is_error`: boolean（status_code >= 400）
- `processed_at`: DataBrew実行時刻

---

## 設計方針

### Global Accelerator の役割
- 静的 Anycast IP を2つ提供（グローバルエントリーポイント）
- AWS グローバルネットワーク経由でALBにルーティング（パブリックインターネット回避）
- ヘルスチェックによる自動フェイルオーバー対応
- 今回は単一リージョン構成だが、マルチリージョン拡張の設計を意識

### Kinesis Data Firehose の役割
- Lambda から直接 S3 に書くのではなく Firehose 経由にすることで：
  - バッファリングによるS3小ファイル問題の解消
  - 自動リトライ・エラーレコードの別保存
  - 将来的なOpenSearch/Redshift連携への拡張性
- バッファ設定: 60秒 or 5MB（どちらか先に達したら書き込み）

### Glue DataBrew の役割
- コードを書かずにGUIベースでETLレシピを定義（ノーコードETL）
- Terraform でレシピをコード化することで再現性を担保
- 入力: S3 Raw（NDJSON）→ 出力: S3 Processed（Parquet）

---

## コスト見積もり

| サービス | 月額概算 |
|---|---|
| Global Accelerator | $0.025/時 + $0.01/GB = ~$18 |
| ALB | ~$16（最低料金） |
| Lambda（Receiver + Generator） | < $1 |
| Kinesis Data Firehose | $0.029/GB = < $1 |
| Glue DataBrew | $1/DPU時 × 0.5DPU × 数回 = < $1 |
| S3 | < $1 |
| **合計** | **~$36/月** |

> ⚠️ Global AcceleratorとALBが固定コストとして高め。ハンズオン後は速やかに `terraform destroy` を推奨。

---

## 禁止パターン

- S3バケットのパブリックアクセスを有効にしない
- Lambda にアクセスキーをハードコードしない（IAMロール使用）
- Firehose の S3 書き込みに暗号化なし設定にしない（SSE-S3を使用）
- ALB のセキュリティグループにポート80/443以外を開けない
- DataBrew ジョブに AdministratorAccess 相当の権限を付与しない

---

## 実行環境

- **Region**: ap-northeast-1（東京）
- **Terraform**: >= 1.6
- **Provider**: hashicorp/aws >= 5.0
- **Python**: 3.12（Lambda）
- **CI/CD**: GitHub Actions + OIDC認証