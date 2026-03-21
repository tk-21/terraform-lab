"""
anomaly-detector Lambda のユニットテスト

テスト対象:
    - detect_cost_increase      前月比コスト増加の検知
    - detect_service_concentration  サービス集中度の検知
    - detect_new_services       新規サービスの検知
    - run_anomaly_detection     全ルール統合実行

AWS 依存（S3 / DynamoDB）はモックに差し替えて純粋な業務ロジックのみを検証する。
"""

import json
import os
import sys
import unittest
from unittest.mock import MagicMock, patch

# Lambda の src ディレクトリを import パスに追加
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

# 環境変数を設定してからインポート（os.environ の参照をモジュールロード前に解決）
os.environ.setdefault("REPORT_BUCKET_NAME", "test-bucket")
os.environ.setdefault("DYNAMODB_TABLE_NAME", "test-table")
os.environ.setdefault("ENVIRONMENT", "test")
os.environ.setdefault("PROJECT_NAME", "test-project")
os.environ.setdefault("MEDIUM_THRESHOLD_PCT", "20")
os.environ.setdefault("HIGH_THRESHOLD_PCT", "50")
os.environ.setdefault("SERVICE_CONCENTRATION_THRESHOLD", "60")

import index  # noqa: E402


class TestDetectCostIncrease(unittest.TestCase):
    """前月比コスト増加の検知テスト"""

    def test_high_alert_when_increase_exceeds_50pct(self):
        """前月比 50% 超 → HIGH"""
        result = index.detect_cost_increase(current_total=151.0, prev_total=100.0)
        self.assertIsNotNone(result)
        self.assertEqual(result["severity"], "HIGH")
        self.assertEqual(result["type"], "COST_INCREASE")
        self.assertAlmostEqual(result["increase_pct"], 51.0, places=1)

    def test_medium_alert_when_increase_exceeds_20pct(self):
        """前月比 21% 増加 → MEDIUM"""
        result = index.detect_cost_increase(current_total=121.0, prev_total=100.0)
        self.assertIsNotNone(result)
        self.assertEqual(result["severity"], "MEDIUM")
        self.assertAlmostEqual(result["increase_pct"], 21.0, places=1)

    def test_no_alert_when_increase_within_threshold(self):
        """前月比 10% 増加 → 異常なし"""
        result = index.detect_cost_increase(current_total=110.0, prev_total=100.0)
        self.assertIsNone(result)

    def test_no_alert_when_cost_decreased(self):
        """コスト減少 → 異常なし"""
        result = index.detect_cost_increase(current_total=80.0, prev_total=100.0)
        self.assertIsNone(result)

    def test_no_alert_when_prev_total_is_zero(self):
        """前月コストが 0（新規アカウント等）→ スキップ"""
        result = index.detect_cost_increase(current_total=100.0, prev_total=0.0)
        self.assertIsNone(result)

    def test_no_alert_when_prev_total_is_tiny(self):
        """前月コストが極小（$0.005）→ スキップ"""
        result = index.detect_cost_increase(current_total=100.0, prev_total=0.005)
        self.assertIsNone(result)

    def test_high_alert_at_exact_boundary(self):
        """前月比ちょうど 50.1% → HIGH（境界値テスト）"""
        result = index.detect_cost_increase(current_total=150.1, prev_total=100.0)
        self.assertIsNotNone(result)
        self.assertEqual(result["severity"], "HIGH")

    def test_medium_alert_at_exact_boundary(self):
        """前月比ちょうど 20.1% → MEDIUM（境界値テスト）"""
        result = index.detect_cost_increase(current_total=120.1, prev_total=100.0)
        self.assertIsNotNone(result)
        self.assertEqual(result["severity"], "MEDIUM")

    def test_result_contains_required_fields(self):
        """HIGH アラートの返り値に必須フィールドが含まれること"""
        result = index.detect_cost_increase(current_total=200.0, prev_total=100.0)
        self.assertIn("type", result)
        self.assertIn("severity", result)
        self.assertIn("description", result)
        self.assertIn("current_cost", result)
        self.assertIn("prev_cost", result)
        self.assertIn("increase_pct", result)


class TestDetectServiceConcentration(unittest.TestCase):
    """サービス集中度の検知テスト"""

    def _make_services(self, top_cost: float, others: list[float]) -> list[dict]:
        services = [{"service": "Amazon EC2", "cost": top_cost}]
        for i, cost in enumerate(others):
            services.append({"service": f"Service-{i}", "cost": cost})
        return services

    def test_concentration_detected_above_60pct(self):
        """上位サービスが 61% → 検知"""
        services = self._make_services(61.0, [20.0, 19.0])
        result = index.detect_service_concentration(
            current_total=100.0, current_services=services
        )
        self.assertIsNotNone(result)
        self.assertEqual(result["type"], "SERVICE_CONCENTRATION")
        self.assertEqual(result["severity"], "MEDIUM")
        self.assertAlmostEqual(result["concentration_pct"], 61.0, places=1)

    def test_no_detection_below_60pct(self):
        """上位サービスが 59% → 検知されない"""
        services = self._make_services(59.0, [21.0, 20.0])
        result = index.detect_service_concentration(
            current_total=100.0, current_services=services
        )
        self.assertIsNone(result)

    def test_no_detection_at_exact_60pct(self):
        """上位サービスがちょうど 60% → 検知されない（超えた場合のみ検知）"""
        services = self._make_services(60.0, [40.0])
        result = index.detect_service_concentration(
            current_total=100.0, current_services=services
        )
        self.assertIsNone(result)

    def test_no_detection_when_total_cost_is_small(self):
        """総コスト $0.50（テスト環境ノイズ）→ スキップ"""
        services = self._make_services(0.4, [0.1])
        result = index.detect_service_concentration(
            current_total=0.5, current_services=services
        )
        self.assertIsNone(result)

    def test_no_detection_when_services_is_empty(self):
        """サービスリストが空 → スキップ"""
        result = index.detect_service_concentration(
            current_total=100.0, current_services=[]
        )
        self.assertIsNone(result)

    def test_top_service_name_is_correct(self):
        """検知結果に正しいサービス名が含まれること"""
        services = [
            {"service": "Amazon S3", "cost": 70.0},
            {"service": "Amazon EC2", "cost": 30.0},
        ]
        result = index.detect_service_concentration(
            current_total=100.0, current_services=services
        )
        self.assertIsNotNone(result)
        self.assertEqual(result["top_service"], "Amazon S3")


class TestDetectNewServices(unittest.TestCase):
    """新規サービス検知のテスト"""

    def test_new_service_detected(self):
        """前月になかったサービスが $1.00 で出現 → 検知"""
        current = [
            {"service": "Amazon EC2", "cost": 50.0},
            {"service": "AWS Lambda", "cost": 1.0},   # 新規
        ]
        prev = [
            {"service": "Amazon EC2", "cost": 50.0},
        ]
        results = index.detect_new_services(current, prev)
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["service"], "AWS Lambda")
        self.assertEqual(results[0]["type"], "NEW_SERVICE")
        self.assertEqual(results[0]["severity"], "LOW")

    def test_tiny_new_service_not_detected(self):
        """新規サービスが $0.05（無料枠ノイズ）→ 検知しない"""
        current = [{"service": "New Service", "cost": 0.05}]
        prev = []
        results = index.detect_new_services(current, prev)
        self.assertEqual(len(results), 0)

    def test_existing_service_not_detected(self):
        """前月にも存在したサービス → 検知しない"""
        current = [{"service": "Amazon EC2", "cost": 100.0}]
        prev = [{"service": "Amazon EC2", "cost": 80.0}]
        results = index.detect_new_services(current, prev)
        self.assertEqual(len(results), 0)

    def test_multiple_new_services_detected(self):
        """複数の新規サービスが同時に出現 → 全て検知"""
        current = [
            {"service": "Service A", "cost": 10.0},
            {"service": "Service B", "cost": 5.0},
        ]
        prev = []
        results = index.detect_new_services(current, prev)
        self.assertEqual(len(results), 2)

    def test_no_new_services_when_both_empty(self):
        """両月ともサービスなし → 検知なし"""
        results = index.detect_new_services([], [])
        self.assertEqual(len(results), 0)

    def test_boundary_cost_exactly_0_1_detected(self):
        """ちょうど $0.10 の新規サービス → 検知する（境界値）"""
        current = [{"service": "New Service", "cost": 0.10}]
        prev = []
        results = index.detect_new_services(current, prev)
        self.assertEqual(len(results), 1)


class TestRunAnomalyDetection(unittest.TestCase):
    """全ルール統合実行のテスト"""

    def _make_event(
        self,
        current_total: float,
        prev_total: float,
        current_services: list | None = None,
        prev_services: list | None = None,
    ) -> dict:
        return {
            "report_id": "finops-202501-test1234",
            "report_date": "2025-01",
            "current_month": {
                "total_cost": current_total,
                "top_services": current_services or [],
            },
            "prev_month": {
                "total_cost": prev_total,
                "top_services": prev_services or [],
            },
        }

    def test_no_anomalies_in_normal_month(self):
        """正常な月（小幅増加・集中なし・新規なし）→ 異常リストが空"""
        event = self._make_event(
            current_total=105.0,
            prev_total=100.0,
            current_services=[
                {"service": "Amazon EC2", "cost": 40.0},
                {"service": "Amazon RDS", "cost": 35.0},
                {"service": "Amazon S3", "cost": 30.0},
            ],
            prev_services=[
                {"service": "Amazon EC2", "cost": 38.0},
                {"service": "Amazon RDS", "cost": 33.0},
                {"service": "Amazon S3", "cost": 29.0},
            ],
        )
        anomalies = index.run_anomaly_detection(event)
        self.assertEqual(len(anomalies), 0)

    def test_multiple_anomalies_detected_simultaneously(self):
        """コスト急増 + サービス集中 + 新規サービス → 3件全て検知"""
        event = self._make_event(
            current_total=200.0,
            prev_total=100.0,
            current_services=[
                {"service": "Amazon EC2", "cost": 130.0},  # 65% 集中
                {"service": "New Service", "cost": 70.0},  # 新規
            ],
            prev_services=[
                {"service": "Amazon EC2", "cost": 100.0},
            ],
        )
        anomalies = index.run_anomaly_detection(event)
        types = {a["type"] for a in anomalies}
        self.assertIn("COST_INCREASE", types)
        self.assertIn("SERVICE_CONCENTRATION", types)
        self.assertIn("NEW_SERVICE", types)

    def test_high_severity_cost_increase(self):
        """100% 増加 → HIGH アラートが含まれること"""
        event = self._make_event(current_total=200.0, prev_total=100.0)
        anomalies = index.run_anomaly_detection(event)
        severities = {a["severity"] for a in anomalies}
        self.assertIn("HIGH", severities)

    def test_returns_list(self):
        """返り値は常にリスト型であること"""
        event = self._make_event(current_total=100.0, prev_total=100.0)
        result = index.run_anomaly_detection(event)
        self.assertIsInstance(result, list)


class TestHandlerWithMocks(unittest.TestCase):
    """handler 全体のテスト（AWS API はモック）"""

    def _make_event(self) -> dict:
        return {
            "report_id": "finops-202501-test1234",
            "report_date": "2025-01",
            "current_month": {
                "total_cost": 200.0,
                "top_services": [
                    {"service": "Amazon EC2", "cost": 150.0},
                    {"service": "Amazon S3", "cost": 50.0},
                ],
                "s3_key": "raw/2025-01/current_month.json",
            },
            "prev_month": {
                "total_cost": 100.0,
                "top_services": [
                    {"service": "Amazon EC2", "cost": 100.0},
                ],
                "s3_key": "raw/2025-01/prev_month.json",
            },
        }

    @patch("index.save_anomaly_report_to_s3", return_value="anomaly/2025-01/anomaly_report.json")
    @patch("index.update_dynamodb_status")
    def test_handler_returns_anomaly_summary(self, mock_dynamo, mock_s3):
        """handler がイベントに anomalies と anomaly_summary を追加して返すこと"""
        context = MagicMock()
        result = index.handler(self._make_event(), context)

        self.assertIn("anomalies", result)
        self.assertIn("anomaly_summary", result)
        self.assertIsInstance(result["anomalies"], list)
        self.assertIsInstance(result["anomaly_summary"]["count"], int)
        self.assertIn("has_high_severity", result["anomaly_summary"])

    @patch("index.save_anomaly_report_to_s3", return_value="anomaly/2025-01/anomaly_report.json")
    @patch("index.update_dynamodb_status")
    def test_handler_preserves_original_event_fields(self, mock_dynamo, mock_s3):
        """handler が元の event フィールドを損なわないこと"""
        context = MagicMock()
        event = self._make_event()
        result = index.handler(event, context)

        self.assertEqual(result["report_id"], event["report_id"])
        self.assertEqual(result["report_date"], event["report_date"])
        self.assertEqual(result["current_month"]["total_cost"], 200.0)

    @patch("index.save_anomaly_report_to_s3", return_value="anomaly/2025-01/anomaly_report.json")
    @patch("index.update_dynamodb_status")
    def test_handler_detects_high_severity_for_100pct_increase(self, mock_dynamo, mock_s3):
        """前月比 100% 増加の場合 has_high_severity=True になること"""
        context = MagicMock()
        result = index.handler(self._make_event(), context)

        self.assertTrue(result["anomaly_summary"]["has_high_severity"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
