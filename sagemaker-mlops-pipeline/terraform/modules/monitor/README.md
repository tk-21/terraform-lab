# module: monitor

SageMaker Model Monitor によるドリフト検知とアラート通知を管理する。

## 作成するリソース

| リソース | 名前 | 目的 |
|---|---|---|
| Data Quality Monitor | `smp-data-quality-monitor` | 入力データのドリフト検知（PSI > 0.5でアラーム）|
| Model Quality Monitor | `smp-model-quality-monitor` | 予測精度の劣化検知（accuracy < 0.75でアラーム）|
| Monitoring Schedule | `smp-data-quality-schedule` | 1時間ごとにData Quality監視を実行 |
| Monitoring Schedule | `smp-model-quality-schedule` | 1時間ごとにModel Quality監視を実行 |
| Lambda | `smp-drift-handler` | ドリフト検知 → Chatwork通知 + Pipeline再実行 |
| CloudWatch Alarm | `smp-data-drift-alarm` | Data Quality違反を検知 |
| CloudWatch Alarm | `smp-model-quality-alarm` | Model Quality違反を検知 |
| SNS Topic | `smp-monitor-alerts` | Alarm → Lambda のルーティング |

## Data Captureの前提条件

Model Quality MonitorはEndpointへの推論リクエストをS3に収集するため、
Endpointに `data_capture_config` が有効になっていること（このモジュールで設定済み）。

## ベースライン生成

監視を開始する前にベースラインを生成すること：

```bash
# Data Qualityベースライン
python monitor/data_quality_baseline.py \
  --role-arn <ROLE_ARN> \
  --artifacts-bucket <ARTIFACTS_BUCKET> \
  --data-bucket <DATA_BUCKET>

# Model Qualityベースライン
python monitor/model_quality_baseline.py \
  --role-arn <ROLE_ARN> \
  --artifacts-bucket <ARTIFACTS_BUCKET> \
  --endpoint-name smp-inference-endpoint
```

## Inputs

| 変数 | 説明 |
|---|---|
| `prefix` | リソース名プレフィックス |
| `pipeline_role_arn` | Monitorジョブ実行ロールARN |
| `endpoint_name` | 監視対象のEndpoint名 |
| `data_quality_baseline_uri` | ベースラインS3 URI（空文字でベースラインなし起動）|
| `model_quality_baseline_uri` | ベースラインS3 URI（空文字でベースラインなし起動）|
