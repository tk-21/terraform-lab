# ✅Phase 2: SageMaker Pipeline定義（Processing → Training → Evaluation → Register）

## Phase 1で作成したもの（サマリー）

- S3: `smp-artifacts-{account_id}`, `smp-data-{account_id}`
- ECR: `smp-processing`, `smp-training`
- IAM: `smp-pipeline-role`, `smp-endpoint-role`, `smp-lambda-base-role`
- VPC Endpoints: SageMaker API/Runtime, S3
- SSM: `/smp/chatwork/*`, `/smp/config/model_approval_threshold`
- Terraform outputs: `artifacts_bucket_name`, `pipeline_role_arn` など

---

## このフェーズで作成するもの

SageMaker Pipelines Python SDKでパイプライン全体を定義し、
Terraformで `aws_sagemaker_pipeline` リソースとして管理する。
スクリプトはモデル非依存（サンプルデータで動作確認できるダミー実装）にする。

---

## タスク一覧

### 1. pipeline/scripts/preprocess.py の実装

Processing Jobで実行される前処理スクリプト。
SageMaker Processing Jobのコンテナ内で動作する。

```python
"""
前処理スクリプト - SageMaker Processing Job用

設計意図:
- このスクリプトはモデル非依存の汎用テンプレート
- 実際のユースケースではここに特徴量エンジニアリングを追加する
- 入力: /opt/ml/processing/input/raw/ にCSVファイル
- 出力: /opt/ml/processing/output/train/ と /test/ に分割済みデータ
"""
import argparse
import os
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

def preprocess(input_dir: str, output_train_dir: str, output_test_dir: str,
               test_size: float = 0.2) -> None:
    """
    データ前処理のメイン処理
    - 欠損値除去
    - 標準化
    - 学習/テスト分割
    """
    # 入力ファイルの読み込み
    input_files = [f for f in os.listdir(input_dir) if f.endswith('.csv')]
    if not input_files:
        raise ValueError(f"CSVファイルが見つかりません: {input_dir}")

    dfs = [pd.read_csv(os.path.join(input_dir, f)) for f in input_files]
    df = pd.concat(dfs, ignore_index=True)
    logger.info(f"入力データ: {len(df)}行, {len(df.columns)}列")

    # 欠損値除去
    df = df.dropna()
    logger.info(f"欠損値除去後: {len(df)}行")

    # 数値列の標準化（目的変数列 'target' を除く）
    feature_cols = [c for c in df.select_dtypes(include='number').columns if c != 'target']
    scaler = StandardScaler()
    df[feature_cols] = scaler.fit_transform(df[feature_cols])

    # 学習/テスト分割
    train_df, test_df = train_test_split(df, test_size=test_size, random_state=42)
    logger.info(f"学習データ: {len(train_df)}行 / テストデータ: {len(test_df)}行")

    # 出力
    os.makedirs(output_train_dir, exist_ok=True)
    os.makedirs(output_test_dir, exist_ok=True)
    train_df.to_csv(os.path.join(output_train_dir, 'train.csv'), index=False)
    test_df.to_csv(os.path.join(output_test_dir, 'test.csv'), index=False)
    logger.info("前処理完了")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--test-size', type=float, default=0.2)
    args = parser.parse_args()

    preprocess(
        input_dir='/opt/ml/processing/input/raw',
        output_train_dir='/opt/ml/processing/output/train',
        output_test_dir='/opt/ml/processing/output/test',
        test_size=args.test_size
    )
```

### 2. pipeline/scripts/train.py の実装

Training Jobで実行される学習スクリプト。
XGBoostビルトインコンテナと互換の形式で実装。

```python
"""
学習スクリプト - SageMaker Training Job用

設計意図:
- XGBoostを使った汎用分類/回帰モデルのテンプレート
- SageMakerのハイパーパラメータ渡し規約に準拠
- モデルアーティファクトは /opt/ml/model/ に保存（SageMaker規約）
- 評価メトリクスをCloudWatch Metricsに出力（Pipelinesのメトリクスキャプチャ用）
"""
import argparse
import os
import json
import joblib
import pandas as pd
import xgboost as xgb
from sklearn.metrics import accuracy_score, mean_squared_error
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

def train(train_dir: str, model_dir: str, hyperparams: dict) -> None:
    # 学習データ読み込み
    train_df = pd.read_csv(os.path.join(train_dir, 'train.csv'))
    X = train_df.drop('target', axis=1)
    y = train_df['target']

    # モデル学習
    model = xgb.XGBClassifier(
        n_estimators=int(hyperparams.get('n_estimators', 100)),
        max_depth=int(hyperparams.get('max_depth', 6)),
        learning_rate=float(hyperparams.get('learning_rate', 0.1)),
        random_state=42,
        use_label_encoder=False,
        eval_metric='logloss'
    )
    model.fit(X, y)

    # CloudWatch Metricsに出力（SageMakerがキャプチャ）
    train_acc = accuracy_score(y, model.predict(X))
    # 出力形式: "metricName: value" でCloudWatch Logsに書き出す
    print(f"train:accuracy: {train_acc:.4f}")
    logger.info(f"学習精度: {train_acc:.4f}")

    # モデル保存（SageMaker規約: /opt/ml/model/ に保存）
    os.makedirs(model_dir, exist_ok=True)
    joblib.dump(model, os.path.join(model_dir, 'model.joblib'))
    logger.info("モデル保存完了")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--n-estimators', type=int, default=100)
    parser.add_argument('--max-depth', type=int, default=6)
    parser.add_argument('--learning-rate', type=float, default=0.1)
    # SageMaker標準の環境変数からパスを取得
    parser.add_argument('--train', type=str,
                        default=os.environ.get('SM_CHANNEL_TRAIN', '/opt/ml/input/data/train'))
    parser.add_argument('--model-dir', type=str,
                        default=os.environ.get('SM_MODEL_DIR', '/opt/ml/model'))
    args = parser.parse_args()

    train(
        train_dir=args.train,
        model_dir=args.model_dir,
        hyperparams=vars(args)
    )
```

### 3. pipeline/scripts/evaluate.py の実装

Evaluation Jobで実行される評価スクリプト。
評価結果をJSON形式で出力し、Condition Stepが参照する。

```python
"""
評価スクリプト - SageMaker Processing Job（評価用）

設計意図:
- モデルアーティファクトとテストデータを受け取り精度を評価
- 評価結果をevaluation.jsonとして出力
- SageMaker Pipelines の ConditionStep がこのJSONを参照して
  Model Registryへの登録可否を判定する
- 出力形式はSageMaker Clarify互換のMetricsJSON形式に準拠
"""
import json
import os
import joblib
import pandas as pd
from sklearn.metrics import accuracy_score, classification_report
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO)

def evaluate(model_dir: str, test_dir: str, output_dir: str) -> None:
    # モデル読み込み
    model = joblib.load(os.path.join(model_dir, 'model.joblib'))

    # テストデータ読み込み
    test_df = pd.read_csv(os.path.join(test_dir, 'test.csv'))
    X_test = test_df.drop('target', axis=1)
    y_test = test_df['target']

    # 評価
    y_pred = model.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    report = classification_report(y_test, y_pred, output_dict=True)

    logger.info(f"テスト精度: {accuracy:.4f}")
    logger.info(f"分類レポート:\n{classification_report(y_test, y_pred)}")

    # SageMaker Pipelines ConditionStep互換のJSON形式で出力
    evaluation_report = {
        "classification_metrics": {
            "accuracy": {
                "value": accuracy,
                "standard_deviation": "NaN"
            }
        },
        "regression_metrics": {}
    }

    os.makedirs(output_dir, exist_ok=True)
    output_path = os.path.join(output_dir, 'evaluation.json')
    with open(output_path, 'w') as f:
        json.dump(evaluation_report, f)

    logger.info(f"評価レポート保存完了: {output_path}")

if __name__ == '__main__':
    evaluate(
        model_dir='/opt/ml/processing/model',
        test_dir='/opt/ml/processing/input/test',
        output_dir='/opt/ml/processing/evaluation'
    )
```

### 4. pipeline/pipeline_definition.py の実装

SageMaker Pipelines Python SDKでパイプライン全体を定義するメインファイル。

```python
"""
SageMaker Pipelines定義

設計意図:
- このファイルが「パイプラインの設計図」。実行はしない
- terraform/modules/pipeline/ からこのファイルを参照してPipeline定義JSONを生成
- または `python pipeline_definition.py --action upsert` で直接デプロイも可能
- 汎用テンプレートとして、model_package_group_name と threshold のみ変えれば転用可能

パイプラインステップ:
  1. ProcessingStep: 前処理
  2. TrainingStep: 学習（スポットインスタンス）
  3. ProcessingStep: 評価
  4. ConditionStep: 精度閾値チェック
  5a. RegisterModel: 合格時 → Model Registry (PendingApproval)
  5b. FailStep: 不合格時 → パイプライン失敗
"""
import argparse
import boto3
import sagemaker
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.steps import ProcessingStep, TrainingStep
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.conditions import ConditionGreaterThanOrEqualTo
from sagemaker.workflow.fail_step import FailStep
from sagemaker.workflow.model_step import ModelStep
from sagemaker.workflow.parameters import ParameterFloat, ParameterString
from sagemaker.workflow.properties import PropertyFile
from sagemaker.workflow.functions import JsonGet
from sagemaker.processing import ScriptProcessor, ProcessingInput, ProcessingOutput
from sagemaker.estimator import Estimator
from sagemaker.inputs import TrainingInput
from sagemaker.model_metrics import MetricsSource, ModelMetrics
from sagemaker.model import Model
import os

REGION = "ap-northeast-1"
PREFIX = "smp"

def get_pipeline(
    role_arn: str,
    artifacts_bucket: str,
    data_bucket: str,
    pipeline_name: str = f"{PREFIX}-training-pipeline",
    model_package_group_name: str = f"{PREFIX}-model-group",
) -> Pipeline:

    sagemaker_session = sagemaker.Session(
        boto_session=boto3.Session(region_name=REGION)
    )

    # パイプラインパラメータ（実行時に上書き可能）
    accuracy_threshold = ParameterFloat(name="AccuracyThreshold", default_value=0.8)
    input_data_uri = ParameterString(
        name="InputDataUri",
        default_value=f"s3://{data_bucket}/raw/"
    )

    # =====================
    # Step 1: Processing（前処理）
    # =====================
    # AWS提供のScikit-learnビルトインコンテナを使用
    from sagemaker.sklearn.processing import SKLearnProcessor
    sklearn_processor = SKLearnProcessor(
        framework_version="1.2-1",
        instance_type="ml.m5.large",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session,
        # 日本語コメント: タグでコスト管理
        tags=[{"Key": "Project", "Value": "sagemaker-mlops-pipeline"}]
    )

    processing_step = ProcessingStep(
        name="PreprocessingStep",
        processor=sklearn_processor,
        inputs=[
            ProcessingInput(
                source=input_data_uri,
                destination="/opt/ml/processing/input/raw"
            )
        ],
        outputs=[
            ProcessingOutput(
                output_name="train",
                source="/opt/ml/processing/output/train",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/train"
            ),
            ProcessingOutput(
                output_name="test",
                source="/opt/ml/processing/output/test",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/test"
            )
        ],
        code="pipeline/scripts/preprocess.py"
    )

    # =====================
    # Step 2: Training（学習）
    # =====================
    from sagemaker.xgboost import XGBoost
    xgb_estimator = XGBoost(
        entry_point="pipeline/scripts/train.py",
        framework_version="1.7-1",
        instance_type="ml.m5.xlarge",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session,
        # スポットインスタンスでコスト削減（最大70%OFF）
        use_spot_instances=True,
        max_run=3600,
        max_wait=7200,
        hyperparameters={
            "n-estimators": 100,
            "max-depth": 6,
            "learning-rate": 0.1
        },
        output_path=f"s3://{artifacts_bucket}/model-artifacts/",
        metric_definitions=[
            {"Name": "train:accuracy", "Regex": "train:accuracy: ([0-9\\.]+)"}
        ]
    )

    training_step = TrainingStep(
        name="TrainingStep",
        estimator=xgb_estimator,
        inputs={
            "train": TrainingInput(
                s3_data=processing_step.properties.ProcessingOutputConfig.Outputs[
                    "train"
                ].S3Output.S3Uri
            )
        }
    )

    # =====================
    # Step 3: Evaluation（評価）
    # =====================
    evaluation_processor = SKLearnProcessor(
        framework_version="1.2-1",
        instance_type="ml.m5.large",
        instance_count=1,
        role=role_arn,
        sagemaker_session=sagemaker_session
    )

    # 評価結果JSONをConditionStepが参照するためのPropertyFile
    evaluation_report = PropertyFile(
        name="EvaluationReport",
        output_name="evaluation",
        path="evaluation.json"
    )

    evaluation_step = ProcessingStep(
        name="EvaluationStep",
        processor=evaluation_processor,
        inputs=[
            ProcessingInput(
                source=training_step.properties.ModelArtifacts.S3ModelArtifacts,
                destination="/opt/ml/processing/model"
            ),
            ProcessingInput(
                source=processing_step.properties.ProcessingOutputConfig.Outputs[
                    "test"
                ].S3Output.S3Uri,
                destination="/opt/ml/processing/input/test"
            )
        ],
        outputs=[
            ProcessingOutput(
                output_name="evaluation",
                source="/opt/ml/processing/evaluation",
                destination=f"s3://{artifacts_bucket}/pipeline-artifacts/evaluation"
            )
        ],
        code="pipeline/scripts/evaluate.py",
        property_files=[evaluation_report]
    )

    # =====================
    # Step 4: Condition（精度チェック）
    # =====================
    # 評価結果JSONからaccuracy値を取得して閾値と比較
    accuracy_condition = ConditionGreaterThanOrEqualTo(
        left=JsonGet(
            step_name=evaluation_step.name,
            property_file=evaluation_report,
            json_path="classification_metrics.accuracy.value"
        ),
        right=accuracy_threshold
    )

    # =====================
    # Step 5a: RegisterModel（合格時）
    # =====================
    model_metrics = ModelMetrics(
        model_statistics=MetricsSource(
            s3_uri=f"{evaluation_step.arguments['ProcessingOutputConfig']['Outputs'][0]['S3Output']['S3Uri']}/evaluation.json",
            content_type="application/json"
        )
    )

    register_step = ModelStep(
        name="RegisterModelStep",
        step_args=Model(
            image_uri=xgb_estimator.training_image_uri(),
            model_data=training_step.properties.ModelArtifacts.S3ModelArtifacts,
            role=role_arn,
            sagemaker_session=sagemaker_session
        ).register(
            content_types=["application/json"],
            response_types=["application/json"],
            inference_instances=["ml.t2.medium", "ml.m5.large"],
            transform_instances=["ml.m5.large"],
            model_package_group_name=model_package_group_name,
            approval_status="PendingApproval",  # 日本語コメント: 必ず人間承認を経てからデプロイ
            model_metrics=model_metrics
        )
    )

    # =====================
    # Step 5b: Fail（不合格時）
    # =====================
    fail_step = FailStep(
        name="ModelEvaluationFailed",
        error_message="モデル評価が精度閾値を満たしませんでした。学習パラメータを見直してください。"
    )

    condition_step = ConditionStep(
        name="CheckAccuracyCondition",
        conditions=[accuracy_condition],
        if_steps=[register_step],
        else_steps=[fail_step]
    )

    # パイプライン組み立て
    pipeline = Pipeline(
        name=pipeline_name,
        parameters=[accuracy_threshold, input_data_uri],
        steps=[processing_step, training_step, evaluation_step, condition_step],
        sagemaker_session=sagemaker_session
    )

    return pipeline


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=["upsert", "definition"], default="definition")
    parser.add_argument("--role-arn", required=True)
    parser.add_argument("--artifacts-bucket", required=True)
    parser.add_argument("--data-bucket", required=True)
    args = parser.parse_args()

    pipeline = get_pipeline(
        role_arn=args.role_arn,
        artifacts_bucket=args.artifacts_bucket,
        data_bucket=args.data_bucket
    )

    if args.action == "upsert":
        pipeline.upsert(role_arn=args.role_arn)
        print("Pipeline upsert完了")
    else:
        import json
        print(json.dumps(json.loads(pipeline.definition()), indent=2))
```

### 5. terraform/modules/pipeline/ の実装

`terraform/modules/pipeline/main.tf`:

```hcl
# SageMaker Model Package Group（Model Registryのコンテナ）
resource "aws_sagemaker_model_package_group" "main" {
  model_package_group_name        = "${local.prefix}-model-group"
  model_package_group_description = "sagemaker-mlops-pipelineのモデルバージョンを管理するグループ"
  tags                            = local.common_tags
}

# SageMaker Pipeline（pipeline_definition.pyから生成したJSONを使用）
# 注意: pipeline定義JSONは `python pipeline_definition.py --action definition` で生成してから
# terraform/modules/pipeline/pipeline_definition.json として保存すること
resource "aws_sagemaker_pipeline" "main" {
  pipeline_name         = "${local.prefix}-training-pipeline"
  pipeline_display_name = "SMP Training Pipeline"
  pipeline_description  = "前処理→学習→評価→条件分岐→Model Registry登録の自動パイプライン"
  role_arn              = var.pipeline_role_arn

  pipeline_definition = file("${path.module}/pipeline_definition.json")

  tags = local.common_tags
}
```

### 6. サンプルデータ生成スクリプトの作成

**ファイル**: `scripts/generate_sample_data.py`

動作確認用のダミーデータを生成してS3にアップロードするスクリプト:

```python
"""
動作確認用サンプルデータ生成

設計意図:
- 実際のユースケースデータがない状態でパイプラインをE2Eテストするためのダミーデータ
- sklearn.datasets.make_classificationで2クラス分類データを生成
- 生成後にS3データバケットへアップロード
"""
import boto3
import pandas as pd
from sklearn.datasets import make_classification
import argparse
import os

def generate_and_upload(bucket_name: str, n_samples: int = 1000) -> None:
    X, y = make_classification(
        n_samples=n_samples,
        n_features=10,
        n_informative=5,
        random_state=42
    )

    df = pd.DataFrame(X, columns=[f"feature_{i}" for i in range(10)])
    df['target'] = y

    local_path = '/tmp/sample_data.csv'
    df.to_csv(local_path, index=False)

    s3 = boto3.client('s3', region_name='ap-northeast-1')
    s3.upload_file(local_path, bucket_name, 'raw/sample_data.csv')
    print(f"アップロード完了: s3://{bucket_name}/raw/sample_data.csv")
    print(f"データ形状: {df.shape}")

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--n-samples', type=int, default=1000)
    args = parser.parse_args()
    generate_and_upload(args.bucket, args.n_samples)
```

### 7. pipeline/requirements.txt の作成

```
sagemaker>=2.200
boto3>=1.34
pandas>=2.0
scikit-learn>=1.3
xgboost>=1.7
joblib>=1.3
```

---

## 完了条件

- [ ] `pipeline_definition.py` が `--action definition` でJSONを出力できること
- [ ] Processing/Training/Evaluationの各スクリプトがローカルで構文エラーなく動作すること
- [ ] `terraform/modules/pipeline/` の `terraform validate` が通ること
- [ ] `scripts/generate_sample_data.py` でサンプルデータを生成できること

---

## 動作確認コマンド

```bash
# 依存インストール
pip install -r pipeline/requirements.txt

# Pipeline定義JSON出力（AWSへの接続不要）
python pipeline/pipeline_definition.py \
  --action definition \
  --role-arn arn:aws:iam::123456789012:role/smp-pipeline-role \
  --artifacts-bucket smp-artifacts-123456789012 \
  --data-bucket smp-data-123456789012

# サンプルデータ生成・アップロード（AWS接続必要）
python scripts/generate_sample_data.py \
  --bucket smp-data-$(aws sts get-caller-identity --query Account --output text)
```

---

## 次フェーズの予告

Phase 3では以下を実装する:
- EventBridge: Model Registry承認イベント検知
- Lambda: 承認通知（Chatwork）+ 自動デプロイトリガー
- CodePipeline: SageMaker Endpointへのモデルデプロイ自動化（Blue/Green）
- SageMaker Endpoint Terraform定義