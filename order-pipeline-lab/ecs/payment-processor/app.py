"""
決済処理 ECS タスク

Step Functions の ECS RunTask 統合で呼び出される。
環境変数で注文情報を受け取り、決済処理後に DynamoDB を更新して終了する。
"""
import os
import sys
import json
import time
import random
import logging
import boto3
from datetime import datetime, timezone

# なぜ: ECS タスクは CloudWatch Logs に直接出力するため
#       構造化ログを JSON 形式で出力する
logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

dynamodb = boto3.resource("dynamodb", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))


def process_payment(order_id: str, amount: int, reserved_items: list) -> dict:
    """
    決済処理のメインロジック

    なぜ: 実際の決済 API (Stripe, etc.) 呼び出しを模擬
          本番では外部 API を呼び出し、タイムアウトは最大 10分想定
    """
    logger.info(json.dumps({
        "event": "payment_start",
        "order_id": order_id,
        "amount": amount
    }))

    update_order_status(order_id, "PAYMENT_PROCESSING")

    # 決済処理のシミュレーション (2-5秒かかる処理)
    processing_time = random.uniform(2, 5)
    time.sleep(processing_time)

    # なぜ: 5% の確率で決済失敗をシミュレート
    #       Step Functions の Retry/Catch で処理されることを確認するため
    if random.random() < 0.05:
        raise PaymentGatewayException(f"決済ゲートウェイエラー: タイムアウト (order_id={order_id})")

    transaction_id = f"txn-{order_id}-{int(time.time())}"

    logger.info(json.dumps({
        "event": "payment_success",
        "order_id": order_id,
        "transaction_id": transaction_id,
        "processing_seconds": round(processing_time, 2)
    }))

    return {
        "transaction_id": transaction_id,
        "amount": amount,
        "status": "PAID"
    }


def update_order_status(order_id: str, status: str, extra: dict = None):
    """DynamoDB の注文ステータスを更新する"""
    table_name = os.environ["DYNAMODB_TABLE_NAME"]
    table = dynamodb.Table(table_name)

    update_expr = "SET #s = :status, updated_at = :ts"
    expr_values = {
        ":status": status,
        ":ts": datetime.now(timezone.utc).isoformat()
    }

    if extra:
        for key, value in extra.items():
            update_expr += f", {key} = :{key}"
            expr_values[f":{key}"] = value

    table.update_item(
        Key={"order_id": order_id},
        UpdateExpression=update_expr,
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues=expr_values
    )


class PaymentGatewayException(Exception):
    """決済ゲートウェイエラー"""
    pass


def main():
    # なぜ: Step Functions ECS RunTask 統合は環境変数でパラメータを渡す
    order_id = os.environ.get("ORDER_ID")
    amount = int(os.environ.get("AMOUNT", "0"))
    reserved_items_json = os.environ.get("RESERVED_ITEMS", "[]")

    if not order_id:
        logger.error("ORDER_ID 環境変数が設定されていません")
        sys.exit(1)

    reserved_items = json.loads(reserved_items_json)

    logger.info(json.dumps({
        "event": "task_start",
        "order_id": order_id,
        "amount": amount,
        "item_count": len(reserved_items)
    }))

    try:
        result = process_payment(order_id, amount, reserved_items)

        # 決済成功: DynamoDB を更新してタスク正常終了
        update_order_status(
            order_id,
            "PAYMENT_COMPLETED",
            {
                "transaction_id": result["transaction_id"],
                "paid_amount": result["amount"]
            }
        )

        logger.info(json.dumps({
            "event": "task_complete",
            "order_id": order_id,
            "transaction_id": result["transaction_id"]
        }))

        sys.exit(0)  # なぜ: exit code 0 = Step Functions が成功と判断

    except PaymentGatewayException as e:
        logger.error(json.dumps({
            "event": "payment_failed",
            "order_id": order_id,
            "error": str(e)
        }))
        update_order_status(order_id, "PAYMENT_FAILED")
        sys.exit(1)  # なぜ: exit code 非0 = Step Functions が失敗と判断し Retry/Catch が動作

    except Exception as e:
        logger.exception(json.dumps({
            "event": "unexpected_error",
            "order_id": order_id,
            "error": str(e)
        }))
        sys.exit(1)


if __name__ == "__main__":
    main()
