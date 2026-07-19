import os
import signal
import time

import boto3
import structlog

# structlogをJSONモードで設定
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
)

logger = structlog.get_logger()

SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

sqs = boto3.client("sqs", region_name=AWS_REGION)

# SIGTERMを受け取ったらFalseにして現在ループを完了してから終了する
# ECS Fargate Spot中断・Karpenterノード退避の両方に対応するため必須
running = True


def sigterm_handler(signum, frame):
    global running
    logger.info("worker_stopped", reason="SIGTERM received")
    running = False


signal.signal(signal.SIGTERM, sigterm_handler)


def process_message(message: dict) -> None:
    attrs = message.get("MessageAttributes", {})
    job_id = attrs.get("job_id", {}).get("StringValue", "unknown")

    logger.info("job_processing", job_id=job_id)
    # 処理シミュレーション
    time.sleep(2)
    logger.info("job_completed", job_id=job_id)

    # 処理成功後にキューから削除
    sqs.delete_message(
        QueueUrl=SQS_QUEUE_URL,
        ReceiptHandle=message["ReceiptHandle"],
    )


def main():
    logger.info("worker_started")
    while running:
        try:
            response = sqs.receive_message(
                QueueUrl=SQS_QUEUE_URL,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,  # ロングポーリング
                MessageAttributeNames=["All"],
            )
            messages = response.get("Messages", [])
            for msg in messages:
                if not running:
                    break
                try:
                    process_message(msg)
                except Exception as e:
                    # 失敗時はdeleteしない → DLQへ流す
                    attrs = msg.get("MessageAttributes", {})
                    job_id = attrs.get("job_id", {}).get("StringValue", "unknown")
                    logger.error("job_failed", job_id=job_id, error=str(e))
        except Exception as e:
            logger.error("worker_error", error=str(e))
            time.sleep(5)


if __name__ == "__main__":
    main()
