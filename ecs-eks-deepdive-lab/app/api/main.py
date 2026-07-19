import os
import uuid

import boto3
import structlog
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

# アプリ起動時にstructlogをJSONモードで設定
structlog.configure(
    processors=[
        structlog.stdlib.add_log_level,
        structlog.stdlib.add_logger_name,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
)

logger = structlog.get_logger()

app = FastAPI(title="Job API")

SQS_QUEUE_URL = os.environ["SQS_QUEUE_URL"]
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

sqs = boto3.client("sqs", region_name=AWS_REGION)


class JobRequest(BaseModel):
    payload: str


@app.post("/jobs", status_code=202)
def create_job(req: JobRequest):
    job_id = str(uuid.uuid4())
    try:
        sqs.send_message(
            QueueUrl=SQS_QUEUE_URL,
            MessageBody=req.payload,
            MessageAttributes={
                "job_id": {
                    "DataType": "String",
                    "StringValue": job_id,
                }
            },
        )
    except Exception as e:
        logger.error("job_send_failed", job_id=job_id, error=str(e))
        raise HTTPException(status_code=503, detail="Failed to enqueue job")

    logger.info("job_created", job_id=job_id)
    return {"job_id": job_id, "status": "queued"}


@app.get("/health")
def health():
    # ECSヘルスチェック用: 常時200を返す
    return {"status": "ok"}
