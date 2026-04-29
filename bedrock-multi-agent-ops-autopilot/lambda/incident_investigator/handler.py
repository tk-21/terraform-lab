import json
import boto3
from datetime import datetime, timedelta, timezone
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="bmao/incident_investigator")

cloudwatch = boto3.client("cloudwatch")
xray = boto3.client("xray")
config_client = boto3.client("config")


# Supervisorから障害調査を委譲された際の最初の調査ステップ
@tracer.capture_method
def investigate_cloudwatch_alarms(params: dict) -> dict:
    time_range_minutes = int(params.get("time_range_minutes", 60))
    namespace = params.get("namespace")

    try:
        kwargs = {"StateValue": "ALARM", "MaxRecords": 50}
        if namespace:
            kwargs["AlarmNamePrefix"] = ""
        response = cloudwatch.describe_alarms(**kwargs)
        alarms = response.get("MetricAlarms", [])

        if namespace:
            alarms = [a for a in alarms if a.get("Namespace") == namespace]

        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(minutes=time_range_minutes)

        results = []
        for alarm in alarms:
            metric_stats = {}
            if alarm.get("MetricName") and alarm.get("Namespace"):
                try:
                    stats_response = cloudwatch.get_metric_statistics(
                        Namespace=alarm["Namespace"],
                        MetricName=alarm["MetricName"],
                        Dimensions=alarm.get("Dimensions", []),
                        StartTime=start_time,
                        EndTime=end_time,
                        Period=300,
                        Statistics=["Average", "Maximum"],
                    )
                    datapoints = sorted(
                        stats_response.get("Datapoints", []),
                        key=lambda x: x["Timestamp"],
                        reverse=True,
                    )
                    if datapoints:
                        metric_stats = {
                            "latest_average": datapoints[0].get("Average"),
                            "latest_maximum": datapoints[0].get("Maximum"),
                            "unit": datapoints[0].get("Unit"),
                        }
                except Exception as e:
                    logger.warning(f"メトリクス取得失敗: {alarm['AlarmName']}: {e}")

            results.append(
                {
                    "alarm_name": alarm["AlarmName"],
                    "state": alarm["StateValue"],
                    "reason": alarm.get("StateReason", ""),
                    "namespace": alarm.get("Namespace", ""),
                    "metric_name": alarm.get("MetricName", ""),
                    "threshold": alarm.get("Threshold"),
                    "metric_stats": metric_stats,
                }
            )

        metrics.add_metric(name="AlarmsInvestigated", unit=MetricUnit.Count, value=len(results))
        return {"alarms": results, "total_count": len(results), "time_range_minutes": time_range_minutes}

    except Exception as e:
        logger.error(f"CloudWatchアラーム調査エラー: {e}")
        return {"error": str(e), "action": "investigated"}


# マイクロサービス間の障害伝播経路を特定するためのトレース調査
@tracer.capture_method
def investigate_xray_traces(params: dict) -> dict:
    service_name = params.get("service_name", "")
    time_range_minutes = int(params.get("time_range_minutes", 60))

    try:
        end_time = datetime.now(timezone.utc)
        start_time = end_time - timedelta(minutes=time_range_minutes)

        service_graph_response = xray.get_service_graph(
            StartTime=start_time,
            EndTime=end_time,
        )
        services = service_graph_response.get("Services", [])

        if service_name:
            services = [s for s in services if service_name.lower() in s.get("Name", "").lower()]

        filter_expression = "fault = true OR error = true"
        if service_name:
            filter_expression = f'service("{service_name}") AND (fault = true OR error = true)'

        traces_response = xray.get_trace_summaries(
            StartTime=start_time,
            EndTime=end_time,
            FilterExpression=filter_expression,
        )
        trace_summaries = traces_response.get("TraceSummaries", [])

        service_stats = []
        for svc in services:
            stats = svc.get("SummaryStatistics", {})
            ok_count = stats.get("OkCount", 0)
            error_count = stats.get("ErrorStatistics", {}).get("TotalCount", 0)
            fault_count = stats.get("FaultStatistics", {}).get("TotalCount", 0)
            total = ok_count + error_count + fault_count
            error_rate = round((error_count + fault_count) / total * 100, 2) if total > 0 else 0

            service_stats.append(
                {
                    "service_name": svc.get("Name", ""),
                    "service_type": svc.get("Type", ""),
                    "error_rate_percent": error_rate,
                    "ok_count": ok_count,
                    "error_count": error_count,
                    "fault_count": fault_count,
                    "avg_response_time_ms": round(stats.get("TotalResponseTime", 0) / max(total, 1) * 1000, 2),
                }
            )

        error_traces = [
            {
                "trace_id": t.get("Id"),
                "duration_ms": round(t.get("Duration", 0) * 1000, 2),
                "has_error": t.get("HasError", False),
                "has_fault": t.get("HasFault", False),
            }
            for t in trace_summaries[:20]
        ]

        metrics.add_metric(name="TracesInvestigated", unit=MetricUnit.Count, value=len(trace_summaries))
        return {
            "service_stats": service_stats,
            "error_traces": error_traces,
            "error_trace_count": len(trace_summaries),
            "time_range_minutes": time_range_minutes,
        }

    except Exception as e:
        logger.error(f"X-Rayトレース調査エラー: {e}")
        return {"error": str(e), "action": "investigated"}


# 設定変更が障害原因でないかConfigルールで確認
@tracer.capture_method
def check_config_compliance(params: dict) -> dict:
    resource_type = params.get("resource_type")

    try:
        response = config_client.get_compliance_summary_by_config_rule()
        compliance_summaries = response.get("ComplianceSummariesByConfigRule", [])

        non_compliant = []
        for summary in compliance_summaries:
            rule_name = summary.get("ConfigRuleName", "")
            compliance = summary.get("Compliance", {})
            if compliance.get("ComplianceType") == "NON_COMPLIANT":
                counts = compliance.get("ComplianceContributorCount", {})
                non_compliant.append(
                    {
                        "rule_name": rule_name,
                        "non_compliant_count": counts.get("CappedCount", 0),
                    }
                )

        if resource_type and non_compliant:
            details = []
            for item in non_compliant:
                try:
                    resources_response = config_client.get_compliance_details_by_config_rule(
                        ConfigRuleName=item["rule_name"],
                        ComplianceTypes=["NON_COMPLIANT"],
                    )
                    for result in resources_response.get("EvaluationResults", []):
                        qualifier = result.get("EvaluationResultIdentifier", {}).get(
                            "EvaluationResultQualifier", {}
                        )
                        if resource_type.lower() in qualifier.get("ResourceType", "").lower():
                            details.append(
                                {
                                    "rule_name": item["rule_name"],
                                    "resource_id": qualifier.get("ResourceId", ""),
                                    "resource_type": qualifier.get("ResourceType", ""),
                                }
                            )
                except Exception as e:
                    logger.warning(f"Configルール詳細取得失敗: {item['rule_name']}: {e}")

            metrics.add_metric(name="NonCompliantResources", unit=MetricUnit.Count, value=len(details))
            return {"non_compliant_resources": details, "total_count": len(details)}

        metrics.add_metric(name="NonCompliantRules", unit=MetricUnit.Count, value=len(non_compliant))
        return {"non_compliant_rules": non_compliant, "total_count": len(non_compliant)}

    except Exception as e:
        logger.error(f"Config準拠確認エラー: {e}")
        return {"error": str(e), "action": "investigated"}


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict, context) -> dict:
    logger.info("障害調査Agent Action Group呼び出し", extra={"event": event})

    function_name = event.get("function", "")
    parameters = {p["name"]: p["value"] for p in event.get("parameters", [])}

    dispatch = {
        "investigate_cloudwatch_alarms": investigate_cloudwatch_alarms,
        "investigate_xray_traces": investigate_xray_traces,
        "check_config_compliance": check_config_compliance,
    }

    if function_name not in dispatch:
        result = {"error": f"不明な関数: {function_name}", "action": "investigated"}
    else:
        result = dispatch[function_name](parameters)

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "function": function_name,
            "functionResponse": {
                "responseBody": {
                    "TEXT": {
                        "body": json.dumps(result, ensure_ascii=False, default=str)
                    }
                }
            },
        },
    }
