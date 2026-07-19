"""
GPU Spotノードのスケールイベントを Chatwork に通知する Lambda

EventBridge (EC2 Instance State-change) → このLambda → Chatwork

EC2 state-change イベントにはinstance-typeが含まれないため
DescribeInstances で動的に取得しg4dn/g5のみフィルタリングする
"""
import urllib.parse
import urllib.request

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="scale-notify-lambda")
ssm = boto3.client("ssm", region_name="ap-northeast-1")
ec2 = boto3.client("ec2", region_name="ap-northeast-1")


def _get_instance_type(instance_id: str) -> str:
    """EC2 DescribeInstances でインスタンスタイプを取得する"""
    try:
        resp = ec2.describe_instances(InstanceIds=[instance_id])
        reservations = resp.get("Reservations", [])
        if not reservations:
            return "unknown"
        return reservations[0]["Instances"][0].get("InstanceType", "unknown")
    except Exception as e:
        logger.warning("DescribeInstances失敗", instance_id=instance_id, error=str(e))
        return "unknown"


def _get_chatwork_credentials() -> tuple[str, str]:
    """SSM から Chatwork 認証情報を取得する (SecureString は復号して返す)"""
    token = ssm.get_parameter(Name="/chatwork/token", WithDecryption=True)
    room = ssm.get_parameter(Name="/chatwork/room-id")
    return token["Parameter"]["Value"], room["Parameter"]["Value"]


def _send_chatwork(message: str) -> None:
    """Chatwork REST API v2 へメッセージを送信する"""
    token, room_id = _get_chatwork_credentials()
    data = urllib.parse.urlencode({"body": message}).encode()
    req = urllib.request.Request(
        f"https://api.chatwork.com/v2/rooms/{room_id}/messages",
        data=data,
        headers={
            "X-ChatWorkToken": token,
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        logger.info("Chatwork通知送信完了", status=resp.status)


@logger.inject_lambda_context
def handler(event: dict, context: LambdaContext) -> dict:
    """
    EventBridge から渡される EC2 Instance State-change イベントを処理する

    GPUインスタンス (g4dn / g5) の起動・終了のみ通知し、
    CPU系ノードのイベントはスキップする
    """
    detail = event.get("detail", {})
    instance_id = detail.get("instance-id", "unknown")
    state = detail.get("state", "")

    # EC2 state-change イベントにはinstance-typeが含まれないためAPIで取得する
    instance_type = _get_instance_type(instance_id)

    # GPUノード (g4dn / g5) 以外はCPUワークロード用ノードのため通知不要
    is_gpu_node = any(family in instance_type for family in ["g4dn", "g5"])
    if not is_gpu_node:
        logger.info("非GPUノードのためスキップ", instance_type=instance_type, state=state)
        return {"statusCode": 200}

    if state == "running":
        # GPU Spotノード起動: vLLMコールドスタート開始を通知する
        # この時点ではまだvLLMは起動していない (約5分後に推論可能になる)
        message = (
            "[info][title]GPU Spot ノード起動[/title]\n"
            f"インスタンス: {instance_type} ({instance_id})\n"
            "vLLMの初期化中 ... 約5分でリクエスト受付可能になります\n"
            "コールドスタート中はBedrockが自動的にカバーしています\n"
            "[/info]"
        )
        _send_chatwork(message)
        logger.info("GPU起動通知送信", instance_type=instance_type, instance_id=instance_id)

    elif state == "terminated":
        # GPU Spotノード返却: KEDAのscale-to-zero + Karpenter consolidationの成果を通知する
        # アイドル時間のGPU費用 ($0.16/h) が課金停止したことを知らせる
        message = (
            "[info][title]GPU Spot ノード返却[/title]\n"
            f"インスタンス: {instance_type} ({instance_id})\n"
            "Karpenter がアイドルノードを返却しました (コスト最適化)\n"
            "次のリクエスト到着時に自動で再プロビジョニングされます\n"
            "[/info]"
        )
        _send_chatwork(message)
        logger.info("GPU返却通知送信", instance_type=instance_type, instance_id=instance_id)

    return {"statusCode": 200}
