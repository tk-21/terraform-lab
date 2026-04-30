# SageMaker Pipelinesで本番MLOps基盤を作った話
# ― モデル学習から監視まで完全自動化

## はじめに

機械学習モデルを本番環境に届けるまでの道のりは長い。
データ加工・学習・評価・デプロイ・監視を手作業でこなしていると、
「先週デプロイしたモデルの精度が今週急落した」「誰がいつ承認したかわからない」
といった問題が必ず起きる。

本記事では AWS SageMaker Pipelines を中心に、モデル非依存の汎用MLOps基盤を
Terraform + Python で構築した実装を解説する。

インフラエンジニアがMLOpsを設計すると「手動作業をいかにゼロにするか」
「コストをどう制御するか」という観点が強くなる。その視点を共有したい。

---

## アーキテクチャ全体像

```
S3(データ)
  └─ SageMaker Pipelines
       ├─ Processing Step   （前処理・特徴量エンジニアリング）
       ├─ Training Step     （XGBoost・スポットインスタンス）
       ├─ Evaluation Step   （精度評価）
       ├─ Condition Step    （accuracy >= 0.8?）
       └─ Register Step     （Model Registry: PendingApproval）
             │
             ▼ EventBridge(PendingApproval検知)
       Lambda（Chatwork通知）
             │
             ▼ 人間による承認
       EventBridge(Approved検知)
             │
             ▼
       CodePipeline → SageMaker Endpoint（Blue/Green）
             │
             ▼
       Model Monitor（Data Quality + Model Quality、1時間スケジュール）
             │ アラーム
             ▼
       Lambda（Chatwork通知 + Pipeline再実行トリガー）
```

全リソースはTerraformで管理し、`terraform apply` 一発で環境を再現できる。

---

## 実装のポイント

### 1. SageMaker Pipelinesのステップ設計

ConditionStepとPropertyFileを組み合わせてEvaluation結果を判定する。

```python
# evaluate.py: 評価結果をPropertyFileに書き出す
evaluation_report = {
    "metrics": {
        "accuracy": {"value": accuracy},
        "auc": {"value": auc}
    }
}
with open("/opt/ml/processing/evaluation/evaluation.json", "w") as f:
    json.dump(evaluation_report, f)
```

```python
# pipeline_definition.py: PropertyFileとJsonGetで条件分岐
evaluation_report = PropertyFile(
    name="EvaluationReport",
    output_name="evaluation",
    path="evaluation.json"
)

accuracy_condition = ConditionGreaterThanOrEqualTo(
    left=JsonGet(
        step_name=evaluation_step.name,
        property_file=evaluation_report,
        json_path="metrics.accuracy.value"
    ),
    right=accuracy_threshold
)

condition_step = ConditionStep(
    name="CheckAccuracy",
    conditions=[accuracy_condition],
    if_steps=[register_step],
    else_steps=[fail_step]
)
```

**ハマりポイント**: `JsonGet` の `json_path` はドット記法で深い階層を参照できるが、
`evaluation.json` のキー構造がSageMakerの期待する形式と合わないとConditionStepが
常にFalseになる。実際のJSONと `json_path` の対応を必ず確認すること。

---

### 2. スポットインスタンスで学習コストを削減

Training Stepにスポットインスタンスを設定するだけで最大70%コスト削減できる。

```python
training_step = TrainingStep(
    name="TrainModel",
    estimator=XGBoost(
        # ...
        use_spot_instances=True,
        max_wait=7200,        # スポット取得待ちの上限（秒）
        max_run=3600,         # 最大実行時間（秒）
        checkpoint_s3_uri=f"s3://{artifacts_bucket}/checkpoints/",
    ),
)
```

**注意点**: `max_wait >= max_run` が必須。これを守らないと
「Spot instance request not fulfilled」エラーになる。
またチェックポイント設定がないと中断時に学習がゼロからやり直しになる。

---

### 3. Human-in-the-loop承認フロー

Model Registryの `PendingApproval` → `Approved` のステータス変化を
EventBridgeで拾い、ChatworkへのLambda通知と接続する。

```python
# approval_notifier/handler.py
# AWS Lambda Powertools必須（Logger/Tracer/Metrics）
@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> None:
    model_package_arn = event["detail"]["ModelPackageArn"]
    approval_status = event["detail"]["ModelApprovalStatus"]

    room_id = ssm.get_parameter(Name="/smp/chatwork/room_id", WithDecryption=True)
    api_token = ssm.get_parameter(Name="/smp/chatwork/api_token", WithDecryption=True)

    message = f"[info][title]モデル承認依頼[/title]\n"
    message += f"ARN: {model_package_arn}\n"
    message += f"ステータス: {approval_status}\n"
    message += f"承認コマンド:\naws sagemaker update-model-package \\\n"
    message += f"  --model-package-arn {model_package_arn} \\\n"
    message += f"  --model-approval-status Approved[/info]"

    # Chatwork API: application/x-www-form-urlencoded
    requests.post(
        f"https://api.chatwork.com/v2/rooms/{room_id}/messages",
        headers={"X-ChatWorkToken": api_token},
        data={"body": message}
    )
```

---

### 4. Blue/Greenデプロイでダウンタイムゼロ

`deployment_config` に `BlueGreenUpdatePolicy` を設定するだけで、
SageMakerが自動的にトラフィックを新バージョンに切り替える。

```hcl
# terraform/modules/endpoint/main.tf
resource "aws_sagemaker_endpoint" "this" {
  name                 = "${var.prefix}-inference-endpoint"
  endpoint_config_name = aws_sagemaker_endpoint_configuration.this.name

  deployment_config {
    blue_green_update_policy {
      traffic_routing_configuration {
        type                     = "ALL_AT_ONCE"
        wait_interval_in_seconds = 300
      }
      termination_wait_in_seconds = 300
    }
  }
}
```

---

### 5. Model Monitorでドリフトを自動検知

Data Qualityは入力データの統計的変化を、Model Qualityは予測精度の劣化を監視する。
2種類のMonitorを使い分けることで、「データが変わったのか」「モデルが劣化したのか」
を区別して対応できる。

```python
# monitor/data_quality_baseline.py
data_quality_monitor = DefaultModelMonitor(
    role=pipeline_role_arn,
    instance_count=1,
    instance_type="ml.m5.large",
)

data_quality_monitor.suggest_baseline(
    baseline_dataset=f"s3://{data_bucket}/baseline/train.csv",
    dataset_format=DatasetFormat.csv(header=True),
    output_s3_uri=f"s3://{artifacts_bucket}/baseline/data-quality/",
)
```

CloudWatch Alarm → SNS → Lambda のチェーンで、
PSI > 0.5（データドリフト）や accuracy < 0.75（モデル品質劣化）を検知したら
自動でPipelineを再実行する。

**ハマりポイント**: Model Quality MonitorはEndpointの **Data Captureが有効**でないと
推論ログを収集できない。Data Captureなしで設定しても監視ジョブが空振りする。

---

### 6. Terraform IaCで全リソースを管理

`AmazonSageMakerFullAccess` からの最小権限リファクタリングをTerraformで管理する例：

```hcl
# modules/foundation/iam.tf
# ADR-002: AmazonSageMakerFullAccessを廃止し最小権限インラインポリシーへ移行
resource "aws_iam_role_policy" "pipeline_minimal" {
  name = "${var.prefix}-pipeline-minimal-policy"
  role = aws_iam_role.pipeline.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sagemaker:CreateProcessingJob",
          "sagemaker:CreateTrainingJob",
          # ... 実際に使うアクションのみ列挙
        ]
        Resource = "*"
      },
      # Pipeline ARNをプロジェクトスコープに絞り込み
      {
        Effect   = "Allow"
        Action   = ["sagemaker:StartPipelineExecution"]
        Resource = "arn:aws:sagemaker:ap-northeast-1:*:pipeline/smp-*"
      },
    ]
  })
}
```

---

## ハマったポイント集

### PropertyFileとJsonGetの組み合わせ

`evaluation.json` のネスト構造と `json_path` の書き方が合わないと
ConditionStepが期待通りに動かない。SageMakerが期待するのは
`metrics.accuracy.value` 形式のドット記法。

### スポットインスタンスの `max_wait` 設定

`max_wait < max_run` にするとバリデーションエラー。
`max_wait = max_run * 2` を基準に設定するのが安全。

### Data CaptureなしでModel Monitorが動かない問題

Model Quality MonitorはEndpointの推論ログを素材として動く。
Endpointに `DataCaptureConfig` を設定し、S3への書き出しを有効にしないと
監視ジョブが「データなし」で終わる。

### CodePipelineとEventBridgeのIAM循環参照

registryモジュール（EventBridge）がendpointモジュール（CodePipeline ARN）を参照し、
endpointモジュールがregistryモジュールに依存するという循環が起きやすい。
Terraformのモジュール依存順を `endpoint → registry` に固定して解消した。

---

## まとめ

インフラエンジニアがMLOpsを設計すると、以下の点に特にこだわりが出る：

1. **手動作業をゼロにする**: 承認以外の全工程を自動化
2. **コストを制御する**: スポットインスタンス・Endpoint停止・Monitorスケジュール最適化
3. **最小権限原則を守る**: `FullAccess` からの卒業をADRとして記録
4. **IaCで全管理**: `terraform destroy` で全リソースを確実に削除できる

本プロジェクトのコードは GitHub で公開している。
モデルに依存しない骨格設計なので、XGBoost以外のアルゴリズムにも流用できる。
