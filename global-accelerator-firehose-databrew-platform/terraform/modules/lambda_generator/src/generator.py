import json
import os
import random
import time
import urllib.error
import urllib.request
from collections import defaultdict

from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()

METHODS = ["GET"] * 6 + ["POST"] * 3 + ["DELETE"]
PATHS = ["/api/users", "/api/products", "/api/orders", "/health"]
USER_AGENTS = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
    "python-requests/2.31.0",
    "curl/7.88.1",
]
REGIONS = ["us-east-1", "eu-west-1", "ap-northeast-1", "ap-southeast-1"]


@logger.inject_lambda_context
def lambda_handler(event: dict, context: LambdaContext) -> dict:
    endpoint = os.environ["ACCELERATOR_ENDPOINT"]
    total = 50
    success_count = 0
    failure_count = 0
    status_counts: dict = defaultdict(int)
    latencies: list = []

    for _ in range(total):
        method = random.choice(METHODS)
        path = random.choice(PATHS)
        user_agent = random.choice(USER_AGENTS)
        region = random.choice(REGIONS)

        url = f"{endpoint}{path}"
        req = urllib.request.Request(
            url,
            method=method,
            headers={
                "User-Agent": user_agent,
                "X-Simulated-Region": region,
            },
        )
        if method == "POST":
            req.data = b"{}"
            req.add_header("Content-Type", "application/json")

        start = time.time()
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                status = resp.status
                status_counts[status] += 1
                success_count += 1
        except urllib.error.HTTPError as e:
            status_counts[e.code] += 1
            failure_count += 1
        except Exception as e:
            logger.warning("Request failed", error=str(e))
            failure_count += 1
        finally:
            latencies.append(int((time.time() - start) * 1000))

        time.sleep(0.1)

    avg_latency = int(sum(latencies) / len(latencies)) if latencies else 0

    logger.info(
        "Generation complete",
        success=success_count,
        failure=failure_count,
        status_counts=dict(status_counts),
        avg_latency_ms=avg_latency,
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "success": success_count,
            "failure": failure_count,
            "avg_latency_ms": avg_latency,
        }),
    }
