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
