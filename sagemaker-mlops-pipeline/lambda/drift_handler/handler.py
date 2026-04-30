"""
Model Monitorドリフト検知ハンドラー Lambda

設計意図:
- CloudWatch Alarm → SNS → このLambdaの流れでドリフトを検知したときに起動
- Chatworkにアラート通知を送信
- 同時にSageMaker Pipelineを再実行して最新データでモデルを再学習
- 再学習は自動実行するが、デプロイは人間承認フロー（Phase3）を経由するため安全
"""
import json
import datetime
import urllib.parse
import urllib.request
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="SMP/DriftHandler")

ssm = boto3.client('ssm', region_name='ap-northeast-1')
sagemaker = boto3.client('sagemaker', region_name='ap-northeast-1')

PIPELINE_NAME = "smp-training-pipeline"
PREFIX = "smp"


def get_ssm_params() -> tuple[str, str]:
    """SSMからChatwork認証情報を取得"""
    response = ssm.get_parameters(
        Names=['/smp/chatwork/room_id', '/smp/chatwork/api_token'],
        WithDecryption=True
    )
    params = {p['Name']: p['Value'] for p in response['Parameters']}
    return params['/smp/chatwork/room_id'], params['/smp/chatwork/api_token']


def send_chatwork_message(room_id: str, api_token: str, message: str) -> None:
    """Chatwork APIにメッセージ送信"""
    url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
    data = urllib.parse.urlencode({'body': message}).encode('utf-8')
    req = urllib.request.Request(
        url, data=data,
        headers={'X-ChatWorkToken': api_token},
        method='POST'
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知完了", status_code=resp.status)


def trigger_retraining() -> str:
    """SageMaker Pipelineを再実行して最新データで再学習"""
    execution_name = f"retrain-{datetime.datetime.now().strftime('%Y%m%d%H%M%S')}"

    response = sagemaker.start_pipeline_execution(
        PipelineName=PIPELINE_NAME,
        PipelineExecutionDisplayName=execution_name,
        PipelineExecutionDescription="Model Monitorドリフト検知による自動再学習",
    )

    logger.info("パイプライン再実行開始", execution_arn=response['PipelineExecutionArn'])
    return response['PipelineExecutionArn']


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    logger.info("ドリフト検知イベント受信", event=event)

    for record in event.get('Records', []):
        sns_message = json.loads(record['Sns']['Message'])
        alarm_name = sns_message.get('AlarmName', 'Unknown')
        alarm_state = sns_message.get('NewStateValue', 'Unknown')
        alarm_reason = sns_message.get('NewStateReason', '')

        if alarm_state != 'ALARM':
            logger.info("ALARMでないイベントをスキップ", state=alarm_state)
            continue

        # ドリフトタイプの判定
        if 'data-drift' in alarm_name:
            drift_type = "データドリフト（入力データの分布変化）"
            action = "再学習パイプラインを自動起動します"
        elif 'model-quality' in alarm_name:
            drift_type = "モデル品質劣化（予測精度の低下）"
            action = "再学習パイプラインを自動起動します"
        else:
            drift_type = "不明なアラーム"
            action = "手動確認が必要です"

        # 再学習トリガー（データドリフト・モデル劣化どちらでも起動）
        execution_arn = trigger_retraining()

        # Chatwork通知
        message = (
            f"[info][title]⚠️ MLOps Model Monitor アラート[/title]"
            f"検知種別: {drift_type}\n"
            f"アラーム名: {alarm_name}\n"
            f"検知理由: {alarm_reason}\n\n"
            f"🔄 対応: {action}\n"
            f"パイプライン実行ARN:\n{execution_arn}\n\n"
            f"再学習完了後、新モデルはModel Registryで承認が必要です。[/info]"
        )

        room_id, api_token = get_ssm_params()
        send_chatwork_message(room_id, api_token, message)
        metrics.add_metric(name="DriftDetected", unit="Count", value=1)

    return {"statusCode": 200, "body": "drift handled"}
