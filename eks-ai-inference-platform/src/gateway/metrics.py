from opentelemetry import metrics
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader

# OTEL CollectorのgRPCエンドポイント: クラスター内部からService名で解決できる
_OTEL_ENDPOINT = "http://otel-collector.monitoring.svc.cluster.local:4317"


def init_metrics() -> None:
    # FastAPI起動時に一度だけ呼び出す
    # PeriodicExportingMetricReader: 一定間隔でOTEL CollectorにPushする
    # Pull型(Prometheus scrape)ではなくPush型を選択した理由:
    # AI GatewayはHTTPリクエスト処理中にメトリクスを記録するため
    # スクレイプタイミングと処理タイミングの不一致を避けるためPush型が適切
    reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=_OTEL_ENDPOINT),
        export_interval_millis=15_000,
    )
    provider = MeterProvider(metric_readers=[reader])
    metrics.set_meter_provider(provider)


meter = metrics.get_meter("ai-gateway")

# 推論リクエストのエンドツーエンドレイテンシ (ALB受信 → レスポンス返却まで)
# histogram_quantile(0.99, ...) でP99を算出するためHistogramを使用する
inference_latency = meter.create_histogram(
    name="inference_latency_seconds",
    description="推論リクエストのエンドツーエンドレイテンシ",
    unit="s",
)

# vLLM/Bedrockが生成したトークンの秒間スループット
# KVキャッシュヒット率やバッチサイズとの相関分析に使用する
tokens_per_second = meter.create_histogram(
    name="inference_tokens_per_second",
    description="推論スループット (生成トークン数/秒)",
    unit="tokens/s",
)

# リクエストあたりの推論コスト
# vLLM (Spot料金 × 時間) vs Bedrock (tokens × 単価) を同一軸で比較するために記録する
cost_per_request = meter.create_histogram(
    name="inference_cost_usd",
    description="リクエストあたりの推論コスト",
    unit="USD",
)

# ルーティング先別のリクエスト数
# backend: "vllm" | "bedrock"
# reason:  "cost" | "availability" | "budget_exceeded"
routing_counter = meter.create_counter(
    name="inference_routing_total",
    description="ルーティング先ごとのリクエスト数",
)
