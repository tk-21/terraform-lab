# Phase 4 — センサーシミュレータ / E2Eテスト / ADR / クリーンアップ

## 目標
- IoTセンサーを模擬するPythonシミュレータでKinesisにデータを継続送信する
- E2Eテストでパイプライン全体の動作を数値で確認する
- Architecture Decision Record (ADR) を自分の言葉で記述する
- 全リソースを `terraform destroy` で削除してコスト精算する

---

## Step 1: センサーシミュレータ作成

### `simulator/sensor_simulator.py`
```python
"""
IoTセンサーシミュレータ

実際のセンサーデバイスが送信するようなデータを生成し、
Kinesisストリームに継続的にPutRecordする。

設計方針:
- 複数デバイスを並列シミュレーションする (ThreadPoolExecutor)
- 異常値を一定確率で混入させてエラーハンドリングを検証できるようにする
- 送信結果をリアルタイムに集計してスループットを可視化する
"""

import json
import random
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

import boto3

# シミュレーション設定
STREAM_NAME = "iot-pipeline-stream"
DEVICE_COUNT = 5           # 並列シミュレーションデバイス数
INTERVAL_SECONDS = 2       # 送信間隔 (秒)
ANOMALY_RATE = 0.05        # 異常値混入率 (5%)
DURATION_SECONDS = 120     # シミュレーション実行時間

kinesis = boto3.client("kinesis", region_name="ap-northeast-1")

# スレッドセーフなカウンター
lock = threading.Lock()
stats = {"success": 0, "failure": 0}


def generate_sensor_data(device_id: str) -> dict:
    """センサーデータを生成する。ANOMALY_RATEの確率で異常値を混入する"""
    is_anomaly = random.random() < ANOMALY_RATE

    if is_anomaly:
        # 異常値: 温度が範囲外
        temperature = random.uniform(80, 100)
        status = "critical"
    else:
        temperature = round(random.uniform(20, 35), 1)
        status = "normal"

    return {
        "device_id": device_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "temperature": temperature,
        "humidity": round(random.uniform(40, 80), 1),
        "status": status,
    }


def simulate_device(device_id: str, duration: int):
    """1デバイスのシミュレーション。duration秒間データを送信し続ける"""
    end_time = time.time() + duration
    while time.time() < end_time:
        data = generate_sensor_data(device_id)
        try:
            kinesis.put_record(
                StreamName=STREAM_NAME,
                Data=json.dumps(data).encode("utf-8"),
                # device_idをパーティションキーにすることで
                # 同一デバイスのレコードが同一シャードに入るようにする
                PartitionKey=device_id,
            )
            with lock:
                stats["success"] += 1
        except Exception as e:
            print(f"[{device_id}] 送信エラー: {e}")
            with lock:
                stats["failure"] += 1

        time.sleep(INTERVAL_SECONDS)


def main():
    print(f"シミュレーション開始: {DEVICE_COUNT}デバイス × {DURATION_SECONDS}秒")
    print(f"ストリーム: {STREAM_NAME}")
    print("-" * 50)

    device_ids = [f"device-{i:03d}" for i in range(1, DEVICE_COUNT + 1)]

    with ThreadPoolExecutor(max_workers=DEVICE_COUNT) as executor:
        futures = [
            executor.submit(simulate_device, device_id, DURATION_SECONDS)
            for device_id in device_ids
        ]
        # 10秒ごとに進捗を表示する
        for _ in range(DURATION_SECONDS // 10):
            time.sleep(10)
            with lock:
                total = stats["success"] + stats["failure"]
                rate = stats["success"] / total * 100 if total > 0 else 0
                print(f"進捗: 成功={stats['success']}, 失敗={stats['failure']}, 成功率={rate:.1f}%")

    print("-" * 50)
    print(f"完了: 成功={stats['success']}, 失敗={stats['failure']}")
    return stats


if __name__ == "__main__":
    main()
```

---

## Step 2: E2Eテストスクリプト作成

### `scripts/e2e_test.sh`
```bash
#!/bin/bash
# パイプライン全体のE2Eテスト
# 測定項目: 書き込みレイテンシ、API応答時間、データ欠損率

set -euo pipefail

API_ENDPOINT=$(jq -r '.api_endpoint.value' phase3_outputs.json)
STREAM_NAME="iot-pipeline-stream"
TABLE_NAME="iot-pipeline-table"
DEVICE_ID="e2e-test-device"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "=============================="
echo " IoT Stream Pipeline E2Eテスト"
echo "=============================="

# 1. テストデータ送信
echo ""
echo "--- Step 1: Kinesisにテストレコードを送信 ---"
SEND_TIME=$(date +%s%N)
aws kinesis put-record \
  --stream-name "${STREAM_NAME}" \
  --partition-key "${DEVICE_ID}" \
  --data "$(echo "{\"device_id\":\"${DEVICE_ID}\",\"temperature\":42.0,\"humidity\":55.5,\"status\":\"test\",\"timestamp\":\"${TIMESTAMP}\"}" | base64)" \
  --query 'SequenceNumber' \
  --output text
echo "送信完了"

# 2. DynamoDBへの書き込みを確認 (最大60秒待機)
echo ""
echo "--- Step 2: DynamoDB書き込み確認 (最大60秒待機) ---"
MAX_WAIT=60
ELAPSED=0
WRITE_TIME=""

while [ $ELAPSED -lt $MAX_WAIT ]; do
  RESULT=$(aws dynamodb get-item \
    --table-name "${TABLE_NAME}" \
    --key "{\"device_id\":{\"S\":\"${DEVICE_ID}\"},\"timestamp\":{\"S\":\"${TIMESTAMP}\"}}" \
    --query 'Item.status.S' \
    --output text 2>/dev/null || echo "None")

  if [ "${RESULT}" = "test" ]; then
    WRITE_TIME=$(date +%s%N)
    LATENCY_MS=$(( (WRITE_TIME - SEND_TIME) / 1000000 ))
    echo "✅ DynamoDB書き込み確認: ${LATENCY_MS}ms (Kinesis送信からの経過時間)"
    break
  fi

  sleep 2
  ELAPSED=$((ELAPSED + 2))
  echo "待機中... ${ELAPSED}秒経過"
done

if [ -z "${WRITE_TIME}" ]; then
  echo "❌ タイムアウト: ${MAX_WAIT}秒以内にDynamoDBへの書き込みを確認できませんでした"
  exit 1
fi

# 3. API Gateway経由でデータ取得
echo ""
echo "--- Step 3: API Gateway経由でデータ取得 ---"
API_START=$(date +%s%N)
HTTP_RESPONSE=$(curl -s -o /tmp/api_response.json -w "%{http_code}" \
  "${API_ENDPOINT}/${DEVICE_ID}")
API_END=$(date +%s%N)
API_LATENCY_MS=$(( (API_END - API_START) / 1000000 ))

if [ "${HTTP_RESPONSE}" = "200" ]; then
  COUNT=$(jq '.count' /tmp/api_response.json)
  echo "✅ API応答: HTTP ${HTTP_RESPONSE}, 取得件数=${COUNT}, レイテンシ=${API_LATENCY_MS}ms"
  jq . /tmp/api_response.json
else
  echo "❌ API応答エラー: HTTP ${HTTP_RESPONSE}"
  cat /tmp/api_response.json
  exit 1
fi

# 4. 結果サマリ
echo ""
echo "=============================="
echo " E2Eテスト結果サマリ"
echo "=============================="
echo "Kinesis → DynamoDB レイテンシ: ${LATENCY_MS}ms"
echo "API Gateway レイテンシ:         ${API_LATENCY_MS}ms"
echo "テスト結果: ✅ 全項目PASS"
echo ""
echo "※ 面接でのトーキングポイント:"
echo "  - エンドツーエンドのデータ到達時間を計測して${LATENCY_MS}msを記録"
echo "  - Lambda bisect設定でバッチ失敗の部分リトライを実現"
```

---

## Step 3: ADRを自分の言葉で記述する

### `docs/adr/ADR-001-container-lambda.md`

**注意: 以下はADRのテンプレートです。AI生成ではなく、自分の言葉で記述してください。**

```markdown
# ADR-001: LambdaをコンテナイメージでデプロイしZIPを使わない

## ステータス
承認済み

## コンテキスト
(ここを自分の言葉で埋める: なぜこの判断が必要だったか背景を書く)
例: Kinesisレコードを処理するLambdaを実装するにあたり、
    デプロイ形式としてZIPパッケージとコンテナイメージの2択があった。

## 決定
(ここを自分の言葉で埋める: 何を選んだか)
例: コンテナイメージ (ECRにプッシュしたDockerイメージ) を選択した。

## 理由
(ここを自分の言葉で埋める: なぜそれを選んだか。箇条書き可)
- 
- 
- 

## 却下した選択肢
(ここを自分の言葉で埋める: ZIPを選ばなかった理由)
- 

## 結果
(ここを自分の言葉で埋める: この決定によって得られたことと失ったこと)
良い点:
- 
トレードオフ:
- 
```

---

## Step 4: シミュレーター実行 & E2Eテスト

```bash
# Python依存パッケージをインストール
pip install boto3

# センサーシミュレーター実行 (バックグラウンドで120秒間)
python3 simulator/sensor_simulator.py &
SIMULATOR_PID=$!

# 30秒後にE2Eテストを実行
sleep 30
chmod +x scripts/e2e_test.sh
./scripts/e2e_test.sh

# シミュレーター終了待ち
wait $SIMULATOR_PID

echo "全テスト完了"
```

---

## Step 5: CloudWatch メトリクス確認

```bash
# Lambda処理エラー率を確認
aws cloudwatch get-metric-statistics \
  --namespace AWS/Lambda \
  --metric-name Errors \
  --dimensions Name=FunctionName,Value=iot-pipeline-processor \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'Datapoints[*].{Time:Timestamp,Errors:Sum}' \
  --output table

# Kinesis受信レコード数
aws cloudwatch get-metric-statistics \
  --namespace AWS/Kinesis \
  --metric-name IncomingRecords \
  --dimensions Name=StreamName,Value=iot-pipeline-stream \
  --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'Datapoints[*].{Time:Timestamp,Records:Sum}' \
  --output table
```

---

## Step 6: クリーンアップ (必ず実施)

```bash
source phase2_image_uris.env

cd terraform
terraform destroy \
  -var="processor_image_uri=${PROCESSOR_IMAGE_URI}" \
  -var="reader_image_uri=${READER_IMAGE_URI}" \
  -auto-approve

echo "全AWSリソースを削除しました"

# ECRイメージも手動削除 (Terraformのdestroy対象外の場合)
aws ecr batch-delete-image \
  --repository-name iot-pipeline-processor \
  --image-ids imageTag=latest 2>/dev/null || true

aws ecr batch-delete-image \
  --repository-name iot-pipeline-reader \
  --image-ids imageTag=latest 2>/dev/null || true

echo "クリーンアップ完了"
```

---

## 最終振り返りチェックリスト

### 数値で語れるか？ (面接トーキングポイント)
- [ ] Kinesis → DynamoDB の書き込みレイテンシ: ___ms
- [ ] API Gateway のレスポンスタイム: ___ms
- [ ] シミュレーター実行中の成功率: ___%
- [ ] bisect_on_function_errorが実際に機能したか: Yes / No

### 自分の言葉で説明できるか？
- [ ] KinesisとSQSの違い (なぜKinesisを選んだか)
- [ ] Lambda コンテナとZIPデプロイの使い分け
- [ ] DynamoDBのキー設計とアクセスパターンの関係
- [ ] API Gatewayのプロキシ統合がなぜ便利か
- [ ] bisect_on_function_errorがない場合に何が起きるか

### ADRは自分の言葉で書けたか？
- [ ] `docs/adr/ADR-001-container-lambda.md` を記述済み
- [ ] AI生成ではなく自分の判断と言葉で書いた

---

## 口頭説明チェックポイント ✅

1. **このパイプライン全体を15分で説明してみる** (アーキテクチャ図を書きながら)
2. **障害シナリオ: Lambdaがクラッシュした場合、データはどうなるか？**
3. **スケールアウト: デバイスが1000台になったときの設計変更点は？**
4. **コスト試算: このパイプラインを24時間稼働させたときの概算コストは？**