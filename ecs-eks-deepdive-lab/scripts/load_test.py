#!/usr/bin/env python3
"""
ECS vs EKS ロードテスト & 定量比較スクリプト

使い方:
  python3 scripts/load_test.py --target both \
      --ecs-url http://<ECS_ALB> \
      --eks-url http://<EKS_ALB> \
      --jobs 200 --concurrency 20
"""
import asyncio
import aiohttp
import argparse
import time
import statistics
import json
from datetime import datetime, UTC

# ── デフォルト設定 ────────────────────────────────────────────────────────────
CONCURRENCY = 20    # 同時リクエスト数
TOTAL_JOBS  = 200   # 送信するジョブ総数
JOB_PAYLOAD = {"task": "load-test", "sleep_seconds": 2}


async def post_job(session: aiohttp.ClientSession, url: str) -> float:
    """1 リクエスト送信して応答時間 (ms) を返す。失敗時は -1.0。"""
    start = time.monotonic()
    try:
        async with session.post(
            f"{url}/jobs",
            json=JOB_PAYLOAD,
            timeout=aiohttp.ClientTimeout(total=10),
        ) as resp:
            await resp.text()
            return (time.monotonic() - start) * 1000
    except Exception as e:
        print(f"  ERROR: {e}")
        return -1.0


async def run_load_test(name: str, base_url: str) -> dict:
    """ロードテスト実行 → 統計辞書を返す。"""
    print(f"\n{'='*50}")
    print(f"[{name}] ロードテスト開始: {base_url}")
    print(f"  同時リクエスト: {CONCURRENCY}  総ジョブ数: {TOTAL_JOBS}")
    print(f"  開始時刻: {datetime.now(UTC).isoformat()}")

    semaphore = asyncio.Semaphore(CONCURRENCY)
    test_start = time.monotonic()

    async def bounded_post(session: aiohttp.ClientSession) -> float:
        async with semaphore:
            return await post_job(session, base_url)

    connector = aiohttp.TCPConnector(limit=CONCURRENCY * 2)
    async with aiohttp.ClientSession(connector=connector) as session:
        results = await asyncio.gather(
            *[bounded_post(session) for _ in range(TOTAL_JOBS)]
        )

    total_elapsed = time.monotonic() - test_start
    latencies = sorted(r for r in results if r >= 0)
    errors = sum(1 for r in results if r < 0)

    if not latencies:
        print("  [ERROR] 全リクエスト失敗")
        return {}

    n = len(latencies)
    stats = {
        "name":      name,
        "total":     TOTAL_JOBS,
        "errors":    errors,
        "success":   n,
        "elapsed_s": round(total_elapsed, 2),
        "rps":       round(TOTAL_JOBS / total_elapsed, 1),
        "mean_ms":   round(statistics.mean(latencies), 1),
        "p50_ms":    round(latencies[int(n * 0.50)], 1),
        "p95_ms":    round(latencies[int(n * 0.95)], 1),
        "p99_ms":    round(latencies[int(n * 0.99)], 1),
        "max_ms":    round(max(latencies), 1),
    }

    print(f"\n  ─── 結果 ({name}) ───")
    print(f"  成功: {stats['success']}/{TOTAL_JOBS}  エラー: {errors}")
    print(f"  総時間: {stats['elapsed_s']}s  RPS: {stats['rps']}")
    print(
        f"  レイテンシ  p50={stats['p50_ms']}ms"
        f"  p95={stats['p95_ms']}ms"
        f"  p99={stats['p99_ms']}ms"
        f"  max={stats['max_ms']}ms"
    )
    return stats


def print_comparison(ecs: dict, eks: dict) -> None:
    """ECS vs EKS 定量比較テーブルを標準出力に表示する。"""
    print(f"\n{'='*62}")
    print("  ECS vs EKS 定量比較")
    print(f"{'='*62}")
    header = f"  {'指標':<20} {'ECS (Fargate)':<20} {'EKS (Karpenter)':<20}"
    print(header)
    print(f"  {'-'*58}")
    rows = [
        ("RPS",           "rps",      "req/s"),
        ("p50 レイテンシ", "p50_ms",  "ms"),
        ("p95 レイテンシ", "p95_ms",  "ms"),
        ("p99 レイテンシ", "p99_ms",  "ms"),
        ("エラー数",       "errors",  "件"),
    ]
    for label, key, unit in rows:
        e = f"{ecs.get(key, 'N/A')} {unit}"
        k = f"{eks.get(key, 'N/A')} {unit}"
        print(f"  {label:<20} {e:<20} {k:<20}")
    print(f"{'='*62}")
    print()
    print("※ スケーリング速度は CloudWatch ダッシュボードで確認:")
    print("  ECS: CloudWatch Alarm (60s 評価) → Step Scaling")
    print("  EKS: KEDA pollingInterval=15s → HPA → Karpenter")


async def main() -> None:
    parser = argparse.ArgumentParser(description="ECS vs EKS ロードテスト")
    parser.add_argument("--ecs-url",     help="ECS ALB URL (http://...)")
    parser.add_argument("--eks-url",     help="EKS ALB URL (http://...)")
    parser.add_argument("--target",      choices=["ecs", "eks", "both"], default="both")
    parser.add_argument("--jobs",        type=int, default=TOTAL_JOBS)
    parser.add_argument("--concurrency", type=int, default=CONCURRENCY)
    args = parser.parse_args()

    global TOTAL_JOBS, CONCURRENCY
    TOTAL_JOBS  = args.jobs
    CONCURRENCY = args.concurrency

    ecs_stats: dict = {}
    eks_stats: dict = {}

    if args.target in ("ecs", "both"):
        url = args.ecs_url or input("ECS ALB URL: ").strip()
        ecs_stats = await run_load_test("ECS", url)

    if args.target in ("eks", "both"):
        # ECS テスト後に SQS キューが空になるまで待機
        if args.target == "both":
            print("\n30 秒待機（SQS キューをフラッシュ）...")
            await asyncio.sleep(30)
        url = args.eks_url or input("EKS ALB URL: ").strip()
        eks_stats = await run_load_test("EKS", url)

    if ecs_stats and eks_stats:
        print_comparison(ecs_stats, eks_stats)

    output = {
        "timestamp": datetime.now(UTC).isoformat(),
        "ecs": ecs_stats,
        "eks": eks_stats,
    }
    with open("load_test_results.json", "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2, ensure_ascii=False)
    print("\n結果を load_test_results.json に保存しました")


if __name__ == "__main__":
    asyncio.run(main())
