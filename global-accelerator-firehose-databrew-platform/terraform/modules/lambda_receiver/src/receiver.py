import json
import os
import time
import uuid
from datetime import datetime

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
firehose_client = boto3.client("firehose")

REGION_MAP = {
    "0": "us-east-1",
    "1": "eu-west-1",
    "2": "ap-northeast-1",
    "3": "ap-southeast-1",
}

EDGE_HEADER_MAP = {
    "nrt": "NRT",
    "iad": "IAD",
    "dub": "DUB",
    "sin": "SIN",
}


@logger.inject_lambda_context
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    start_time = time.time()

    headers = event.get("headers") or {}
    x_forwarded_for = headers.get("x-forwarded-for", "")
    ips = [ip.strip() for ip in x_forwarded_for.split(",") if ip.strip()]
    source_ip = ips[0] if ips else "unknown"
    accelerator_ip = ips[-1] if ips else "unknown"

    last_octet = source_ip.split(".")[-1] if "." in source_ip else "0"
    region_key = str(int(last_octet) % 4) if last_octet.isdigit() else "0"
    source_region = REGION_MAP[region_key]

    cf_id = headers.get("x-amz-cf-id", "")
    edge_location = "UNKNOWN"
    if cf_id:
        prefix = cf_id[:3].lower()
        edge_location = EDGE_HEADER_MAP.get(prefix, "UNKNOWN")

    method = event.get("httpMethod", "GET")
    path = event.get("path", "/")
    user_agent = headers.get("user-agent", "unknown")

    latency_ms = int((time.time() - start_time) * 1000)
    request_id = str(uuid.uuid4())

    log_record = {
        "request_id": request_id,
        "timestamp": datetime.utcnow().isoformat(),
        "source_ip": source_ip,
        "source_region": source_region,
        "method": method,
        "path": path,
        "status_code": 200,
        "latency_ms": latency_ms,
        "user_agent": user_agent,
        "accelerator_ip": accelerator_ip,
        "edge_location": edge_location,
    }

    try:
        firehose_client.put_record(
            DeliveryStreamName=os.environ["FIREHOSE_STREAM_NAME"],
            Record={"Data": json.dumps(log_record) + "\n"},
        )
    except Exception as e:
        logger.error("Failed to put record to Firehose", error=str(e))
        return {
            "statusCode": 500,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"status": "error", "message": str(e)}),
        }

    logger.info("Request processed", **log_record)
    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"status": "ok", "request_id": request_id}),
    }
