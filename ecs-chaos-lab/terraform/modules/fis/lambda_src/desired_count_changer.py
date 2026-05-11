"""
FIS シナリオ3用 Lambda: ECS Service の DesiredCount を変更する
FIS から aws:lambda:invoke アクションで呼び出される

環境変数:
  CLUSTER_NAME: ECS クラスター名
  SERVICE_NAME: ECS サービス名
  TARGET_COUNT: 変更後の desired count（デフォルト: 0）
  RESTORE_COUNT: 復元後の desired count（デフォルト: 2）

イベント構造:
  {"action": "set_zero" | "restore"}
"""
import boto3
import os
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client("ecs", region_name="ap-northeast-1")

CLUSTER_NAME = os.environ["CLUSTER_NAME"]
SERVICE_NAME = os.environ["SERVICE_NAME"]
TARGET_COUNT = int(os.environ.get("TARGET_COUNT", "0"))
RESTORE_COUNT = int(os.environ.get("RESTORE_COUNT", "2"))


def lambda_handler(event, context):
    action = event.get("action", "set_zero")
    logger.info(f"アクション: {action}, クラスター: {CLUSTER_NAME}, サービス: {SERVICE_NAME}")

    if action == "set_zero":
        # シナリオ3: DesiredCount を 0 に変更（全 Task 停止）
        desired = TARGET_COUNT
        logger.info(f"DesiredCount を {desired} に変更（全 Task 停止）")
    elif action == "restore":
        # FIS 実験終了後の復旧: DesiredCount を元に戻す
        desired = RESTORE_COUNT
        logger.info(f"DesiredCount を {desired} に復元")
    else:
        raise ValueError(f"不明なアクション: {action}")

    response = ecs.update_service(
        cluster=CLUSTER_NAME,
        service=SERVICE_NAME,
        desiredCount=desired,
        forceNewDeployment=False,
    )

    current = response["service"]["desiredCount"]
    logger.info(f"更新完了: desiredCount = {current}")

    return {
        "statusCode": 200,
        "body": json.dumps({
            "action": action,
            "cluster": CLUSTER_NAME,
            "service": SERVICE_NAME,
            "desiredCount": current,
        }),
    }
