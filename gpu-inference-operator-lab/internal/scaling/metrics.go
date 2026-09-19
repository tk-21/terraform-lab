// Package scaling はPrometheusからGPU使用率・キュー深度を取得するメトリクスクライアントを提供する
//
// KEDAが内部で行っているPrometheus APIポーリングを自前実装することで、
// ポーリング間隔・クエリ・フィルタリングを完全に制御し反応速度を定量比較できるようにする。
package scaling

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"time"
)

// MetricValue はPromQLクエリの評価結果
type MetricValue struct {
	Value     float64
	Timestamp time.Time
}

// MetricsFetcher はPrometheusからスケーリングメトリクスを取得するインターフェース
// テスト時にモック実装に差し替えられるよう抽象化している
type MetricsFetcher interface {
	FetchGPUUtilization(ctx context.Context, namespace, deploymentName string) (MetricValue, error)
	FetchQueueDepth(ctx context.Context, queueName string) (MetricValue, error)
}

// PrometheusMetricsFetcher はPrometheus HTTP APIを直接呼び出してメトリクスを取得する
// KEDAがScaledObject内部でやっていることを自前で実装し、呼び出しタイミングを完全に制御する
type PrometheusMetricsFetcher struct {
	baseURL    string
	httpClient *http.Client
}

// NewPrometheusMetricsFetcher は指定したPrometheus URLに接続するFetcherを返す
func NewPrometheusMetricsFetcher(baseURL string) *PrometheusMetricsFetcher {
	return &PrometheusMetricsFetcher{
		baseURL: baseURL,
		// Prometheus instant queryは通常50ms以内に返るため5秒タイムアウトで十分
		httpClient: &http.Client{
			Timeout: 5 * time.Second,
		},
	}
}

// prometheusQueryResponse はPrometheus instant query APIのレスポンス形式
type prometheusQueryResponse struct {
	Status string `json:"status"`
	Data   struct {
		ResultType string `json:"resultType"`
		Result     []struct {
			Metric map[string]string `json:"metric"`
			Value  [2]interface{}    `json:"value"`
		} `json:"result"`
	} `json:"data"`
}

func (f *PrometheusMetricsFetcher) query(ctx context.Context, promQL string) (float64, error) {
	endpoint := fmt.Sprintf("%s/api/v1/query", f.baseURL)
	params := url.Values{"query": {promQL}}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint+"?"+params.Encode(), nil)
	if err != nil {
		return 0, fmt.Errorf("building prometheus request: %w", err)
	}

	resp, err := f.httpClient.Do(req)
	if err != nil {
		return 0, fmt.Errorf("querying prometheus: %w", err)
	}
	defer resp.Body.Close()

	var result prometheusQueryResponse
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0, fmt.Errorf("decoding prometheus response: %w", err)
	}

	if result.Status != "success" || len(result.Data.Result) == 0 {
		// メトリクスが存在しない=GPUノード未起動またはキュー空。負荷ゼロとして扱う
		return 0, nil
	}

	valStr, ok := result.Data.Result[0].Value[1].(string)
	if !ok {
		return 0, fmt.Errorf("unexpected value type in prometheus response")
	}
	return strconv.ParseFloat(valStr, 64)
}

// FetchGPUUtilization はDCGM ExporterのGPU使用率(0-100%)を取得する
// DCGM_FI_DEV_GPU_UTIL はNVIDIA DCGM Exporterが公開する標準的なGPU使用率メトリクス
// namespace・deployment名でフィルタしてマルチテナント環境でも正確な値を取得する
func (f *PrometheusMetricsFetcher) FetchGPUUtilization(ctx context.Context, namespace, deploymentName string) (MetricValue, error) {
	promQL := fmt.Sprintf(
		`avg(DCGM_FI_DEV_GPU_UTIL{namespace="%s", exported_pod=~"%s-.*"})`,
		namespace, deploymentName,
	)
	val, err := f.query(ctx, promQL)
	if err != nil {
		return MetricValue{}, err
	}
	return MetricValue{Value: val, Timestamp: time.Now()}, nil
}

// FetchQueueDepth はSQSのキュー深度をCloudWatch Exporter経由で取得する
// aws_sqs_approximate_number_of_messages_visible_maximum はCloudWatch Exporterの標準メトリクス名
func (f *PrometheusMetricsFetcher) FetchQueueDepth(ctx context.Context, queueName string) (MetricValue, error) {
	promQL := fmt.Sprintf(
		`aws_sqs_approximate_number_of_messages_visible_maximum{queue_name="%s"}`,
		queueName,
	)
	val, err := f.query(ctx, promQL)
	if err != nil {
		return MetricValue{}, err
	}
	return MetricValue{Value: val, Timestamp: time.Now()}, nil
}
