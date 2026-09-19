#!/usr/bin/env bash
# スケールアウト反応速度計測スクリプト
#
# 負荷注入からreplicas増加までの時間を計測し、
# 自作コントローラーとKEDAの比較データを収集する。
#
# 使い方:
#   ./measure_scale_latency.sh <ais-name> <namespace> <expected-replicas> [output-csv]
#
# 例:
#   ./measure_scale_latency.sh llama-3-8b inference 3 /tmp/latency.csv
#
# 出力形式:
#   timestamp_start,timestamp_replicas_changed,latency_seconds,source_replicas,target_replicas
#
# 事前条件:
#   - kubectl が設定済みであること
#   - AISリソースが存在すること
#   - inject_load.sh を事前に実行してキューにメッセージが入っていること

set -euo pipefail

AIS_NAME="${1:?Usage: $0 <ais-name> <namespace> <expected-replicas> [output-csv]}"
NAMESPACE="${2:?}"
EXPECTED_REPLICAS="${3:?}"
OUTPUT_CSV="${4:-/tmp/scale-latency-$(date +%Y%m%d-%H%M%S).csv}"
POLL_INTERVAL_MS=500  # 500ms間隔でポーリング(計測粒度)
TIMEOUT_SECONDS=120

# CSVヘッダー出力
if [ ! -f "$OUTPUT_CSV" ]; then
    echo "timestamp_start,timestamp_scaled,latency_seconds,from_replicas,to_replicas,controller_type" >> "$OUTPUT_CSV"
fi

echo "[$(date -Iseconds)] Watching ${NAMESPACE}/${AIS_NAME} for scale-out to ${EXPECTED_REPLICAS} replicas..."
echo "[$(date -Iseconds)] Polling interval: ${POLL_INTERVAL_MS}ms, Timeout: ${TIMEOUT_SECONDS}s"

# 計測開始時刻とベースラインのreplicas数を記録
START_TS=$(date +%s%3N)  # ミリ秒精度
START_ISO=$(date -Iseconds)

CURRENT_REPLICAS=$(kubectl get ais "$AIS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
BASELINE_REPLICAS="${CURRENT_REPLICAS:-0}"

echo "[$(date -Iseconds)] Baseline replicas: ${BASELINE_REPLICAS}"

# expected_replicasに達するまでポーリング
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT_SECONDS" ]; do
    CURRENT_REPLICAS=$(kubectl get ais "$AIS_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

    if [ "${CURRENT_REPLICAS:-0}" -ge "$EXPECTED_REPLICAS" ]; then
        END_TS=$(date +%s%3N)
        END_ISO=$(date -Iseconds)
        LATENCY_MS=$(( END_TS - START_TS ))
        LATENCY_S=$(echo "scale=3; $LATENCY_MS / 1000" | bc)

        echo ""
        echo "[${END_ISO}] Scale-out detected!"
        echo "  From: ${BASELINE_REPLICAS} replicas"
        echo "  To:   ${CURRENT_REPLICAS} replicas"
        echo "  Latency: ${LATENCY_S}s (${LATENCY_MS}ms)"

        # 比較実験: カスタムコントローラーとKEDAを区別するためコントローラータイプを記録
        CONTROLLER_TYPE="${CONTROLLER_TYPE:-custom-operator}"
        echo "${START_ISO},${END_ISO},${LATENCY_S},${BASELINE_REPLICAS},${CURRENT_REPLICAS},${CONTROLLER_TYPE}" >> "$OUTPUT_CSV"
        echo "[$(date -Iseconds)] Result saved to ${OUTPUT_CSV}"
        exit 0
    fi

    sleep "$(echo "scale=3; $POLL_INTERVAL_MS / 1000" | bc)"
    ELAPSED=$(( ELAPSED + 1 ))
    printf "."
done

echo ""
echo "[$(date -Iseconds)] TIMEOUT: replicas did not reach ${EXPECTED_REPLICAS} within ${TIMEOUT_SECONDS}s"
echo "  Current replicas: ${CURRENT_REPLICAS:-0}"
echo "${START_ISO},TIMEOUT,-1,${BASELINE_REPLICAS},${CURRENT_REPLICAS:-0},${CONTROLLER_TYPE:-custom-operator}" >> "$OUTPUT_CSV"
exit 1
