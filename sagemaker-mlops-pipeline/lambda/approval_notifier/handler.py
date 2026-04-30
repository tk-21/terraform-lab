"""
Model Registry承認通知Lambda

設計意図:
- SageMaker Model PackageのステータスがPendingApprovalに変わったとき
  担当者にChatwork通知を送り、承認/却下を促す
- 承認操作はAWSコンソールまたはCLIで実施（このLambdaは通知のみ）
- Lambda Powertoolsで構造化ログ出力
"""
import json
import urllib.parse
import urllib.request
import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="SMP/ApprovalNotifier")

ssm = boto3.client('ssm', region_name='ap-northeast-1')


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
        url,
        data=data,
        headers={'X-ChatWorkToken': api_token},
        method='POST'
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知送信完了", status_code=resp.status)


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    """
    EventBridgeからSageMaker Model Package状態変更イベントを受け取る
    イベント構造: event['detail']['ModelPackageStatus'] == 'PendingApproval'
    """
    logger.info("Model Registry イベント受信", event=event)

    detail = event.get('detail', {})
    model_package_arn = detail.get('ModelPackageArn', 'Unknown')
    model_package_name = detail.get('ModelPackageName', 'Unknown')
    status = detail.get('ModelPackageStatus', 'Unknown')
    group_name = detail.get('ModelPackageGroupName', 'Unknown')

    if status == 'PendingApproval':
        # 承認依頼メッセージ
        message = (
            f"[info][title]🤖 MLOpsパイプライン: モデル承認依頼[/title]"
            f"新しいモデルバージョンがModel Registryに登録されました。\n\n"
            f"📦 モデルグループ: {group_name}\n"
            f"🏷️ バージョン: {model_package_name}\n"
            f"📊 ステータス: PendingApproval\n\n"
            f"✅ 承認コマンド:\n"
            f"aws sagemaker update-model-package \\\n"
            f"  --model-package-arn {model_package_arn} \\\n"
            f"  --model-approval-status Approved\n\n"
            f"❌ 却下コマンド:\n"
            f"aws sagemaker update-model-package \\\n"
            f"  --model-package-arn {model_package_arn} \\\n"
            f"  --model-approval-status Rejected[/info]"
        )
    elif status == 'Approved':
        message = (
            f"[info][title]✅ MLOpsパイプライン: モデル承認済み[/title]"
            f"モデルが承認されました。自動デプロイを開始します。\n\n"
            f"📦 モデルグループ: {group_name}\n"
            f"🏷️ バージョン: {model_package_name}[/info]"
        )
    else:
        logger.info("通知対象外のステータス", status=status)
        return {"statusCode": 200, "body": "skip"}

    room_id, api_token = get_ssm_params()
    send_chatwork_message(room_id, api_token, message)

    metrics.add_metric(name="NotificationSent", unit="Count", value=1)
    return {"statusCode": 200, "body": "notification sent"}
