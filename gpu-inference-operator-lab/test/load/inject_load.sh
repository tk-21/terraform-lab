#!/usr/bin/env bash
# 負荷注入スクリプト: SQSキューにメッセージを投入してスケールアウトを誘発する
#
# 使い方:
#   ./inject_load.sh <queue-url> <message-count>
#
# 例:
#   ./inject_load.sh https://sqs.ap-northeast-1.amazonaws.com/123456789/inference-queue 50
#
# 事前条件:
#   - aws CLI が設定済みであること
#   - SQSキューが存在すること
#   - AISリソースに scalingMetric.type=queueDepth, targetValue=10 が設定されていること

set -euo pipefail

QUEUE_URL="${1:?Usage: $0 <queue-url> <message-count>}"
MESSAGE_COUNT="${2:?Usage: $0 <queue-url> <message-count>}"
REGION="${AWS_REGION:-ap-northeast-1}"

echo "[$(date -Iseconds)] Injecting ${MESSAGE_COUNT} messages into ${QUEUE_URL}"

# バッチサイズ10でSQSに投入する(SQS send-message-batchの上限が10)
BATCHES=$(( (MESSAGE_COUNT + 9) / 10 ))
for batch in $(seq 1 "$BATCHES"); do
    ENTRIES=""
    for i in $(seq 1 10); do
        MSG_NUM=$(( (batch - 1) * 10 + i ))
        if [ "$MSG_NUM" -gt "$MESSAGE_COUNT" ]; then
            break
        fi
        ENTRIES="${ENTRIES}{\"Id\":\"msg-${MSG_NUM}\",\"MessageBody\":\"inference-request-${MSG_NUM}\"},"
    done
    ENTRIES="[${ENTRIES%,}]"

    aws sqs send-message-batch \
        --region "$REGION" \
        --queue-url "$QUEUE_URL" \
        --entries "$ENTRIES" \
        --output text > /dev/null
done

echo "[$(date -Iseconds)] Injection complete. ${MESSAGE_COUNT} messages sent."
echo "[$(date -Iseconds)] Run measure_scale_latency.sh to track scale-out timing."
