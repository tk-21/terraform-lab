"""
Lambda Producer: generates dummy events and sends them to MSK Kafka via IAM authentication.
"""
import json
import os
import random
import uuid
from datetime import datetime

from aws_lambda_powertools import Logger
from kafka import KafkaProducer
from aws_msk_iam_sasl_signer import MSKAuthTokenProvider

logger = Logger(service="kafka-producer")

SERVICE_NAMES = ["auth", "api", "payment", "notification"]
ACTIONS = ["login", "request", "charge", "send"]
STATUSES = ["success", "error", "timeout"]
STATUS_WEIGHTS = [0.80, 0.15, 0.05]
REGION = "ap-northeast-1"
BATCH_SIZE = 100


def oauth_cb(oauth_config):
    """SASL OAUTHBEARER callback for MSK IAM authentication."""
    auth_token, expiry_ms = MSKAuthTokenProvider.generate_auth_token(region=REGION)
    return auth_token, expiry_ms / 1000


def create_producer(bootstrap_servers: str) -> KafkaProducer:
    """Create and return a KafkaProducer configured for MSK IAM auth."""
    return KafkaProducer(
        bootstrap_servers=bootstrap_servers.split(","),
        security_protocol="SASL_SSL",
        sasl_mechanism="OAUTHBEARER",
        sasl_oauth_token_provider=oauth_cb,
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
    )


def generate_event() -> dict:
    """Generate a single dummy event matching the required schema."""
    return {
        "event_id": str(uuid.uuid4()),
        "timestamp": datetime.utcnow().isoformat(),
        "service_name": random.choice(SERVICE_NAMES),
        "action": random.choice(ACTIONS),
        "user_id": f"u_{random.randint(1000, 9999)}",
        "latency_ms": random.randint(10, 500),
        "status": random.choices(STATUSES, weights=STATUS_WEIGHTS, k=1)[0],
        "region": REGION,
    }


@logger.inject_lambda_context
def lambda_handler(event, context):
    """Lambda entry point: generates BATCH_SIZE dummy events and sends them to Kafka."""
    bootstrap_servers = os.environ["MSK_BOOTSTRAP_SERVERS"]
    topic = os.environ.get("KAFKA_TOPIC", "streaming-events")

    logger.info("Starting Kafka producer", extra={"topic": topic, "batch_size": BATCH_SIZE})

    producer = create_producer(bootstrap_servers)

    success_count = 0
    failure_count = 0

    for i in range(BATCH_SIZE):
        dummy_event = generate_event()
        try:
            producer.send(topic, value=dummy_event)
            success_count += 1
        except Exception as exc:
            failure_count += 1
            logger.error(
                "Failed to send event",
                extra={
                    "index": i,
                    "event_id": dummy_event.get("event_id"),
                    "error": str(exc),
                },
            )

    producer.flush()

    logger.info(
        "Kafka producer finished",
        extra={
            "success_count": success_count,
            "failure_count": failure_count,
            "topic": topic,
        },
    )

    return {
        "statusCode": 200,
        "body": json.dumps(
            {
                "success_count": success_count,
                "failure_count": failure_count,
            }
        ),
    }
