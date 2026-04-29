import json
import boto3
from datetime import datetime, timedelta, timezone
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit

logger = Logger()
tracer = Tracer()
metrics = Metrics(namespace="bmao/cost_optimizer")

ce_client = boto3.client("ce")
ec2_client = boto3.client("ec2")


# コスト異常の一覧を取得。Supervisorがコスト最適化タスクを判断する際の入力
@tracer.capture_method
def get_cost_anomalies(params: dict) -> dict:
    lookback_days = int(params.get("lookback_days", 7))

    try:
        end_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        start_date = (datetime.now(timezone.utc) - timedelta(days=lookback_days)).strftime("%Y-%m-%d")

        response = ce_client.get_anomalies(
            DateInterval={"StartDate": start_date, "EndDate": end_date},
            MaxResults=20,
        )
        anomalies = response.get("Anomalies", [])

        results = []
        for anomaly in anomalies:
            impact = anomaly.get("Impact", {})
            root_causes = anomaly.get("RootCauses", [])
            service = root_causes[0].get("Service", "Unknown") if root_causes else "Unknown"

            results.append(
                {
                    "anomaly_id": anomaly.get("AnomalyId", ""),
                    "service": service,
                    "total_impact_usd": impact.get("TotalImpact", 0),
                    "expected_spend_usd": impact.get("TotalExpectedSpend", 0),
                    "actual_spend_usd": impact.get("TotalActualSpend", 0),
                    "start_date": anomaly.get("AnomalyStartDate", ""),
                    "end_date": anomaly.get("AnomalyEndDate", ""),
                }
            )

        results.sort(key=lambda x: x["total_impact_usd"], reverse=True)

        metrics.add_metric(name="AnomaliesDetected", unit=MetricUnit.Count, value=len(results))
        return {"anomalies": results, "total_count": len(results), "lookback_days": lookback_days}

    except Exception as e:
        logger.error(f"コスト異常取得エラー: {e}")
        return {"error": str(e), "action": "analyzed"}


# 過剰スペックなEC2インスタンスの最適化候補。自動実行せず推奨のみ返す
@tracer.capture_method
def get_rightsizing_recommendations(params: dict) -> dict:
    try:
        response = ce_client.get_rightsizing_recommendation(
            Service="AmazonEC2",
            Configuration={
                "RecommendationTarget": "SAME_INSTANCE_FAMILY",
                "BenefitsConsidered": True,
            },
        )
        recommendations = response.get("RightsizingRecommendations", [])

        results = []
        for rec in recommendations:
            current = rec.get("CurrentInstance", {})
            modify = rec.get("ModifyRecommendationDetail", {})
            target_instances = modify.get("TargetInstances", [])
            best_target = target_instances[0] if target_instances else {}

            estimated_savings = 0.0
            if best_target:
                savings = best_target.get("EstimatedMonthlySavings", "0")
                try:
                    estimated_savings = float(savings)
                except (ValueError, TypeError):
                    estimated_savings = 0.0

            results.append(
                {
                    "instance_id": current.get("ResourceId", ""),
                    "current_instance_type": current.get("ResourceDetails", {})
                    .get("EC2ResourceDetails", {})
                    .get("InstanceType", ""),
                    "recommended_instance_type": best_target.get("ResourceDetails", {})
                    .get("EC2ResourceDetails", {})
                    .get("InstanceType", ""),
                    "estimated_monthly_savings_usd": estimated_savings,
                    "recommendation_type": rec.get("RightsizingType", ""),
                }
            )

        results.sort(key=lambda x: x["estimated_monthly_savings_usd"], reverse=True)

        metrics.add_metric(name="RightsizingRecommendations", unit=MetricUnit.Count, value=len(results))
        return {"recommendations": results, "total_count": len(results)}

    except Exception as e:
        logger.error(f"右サイジング推奨取得エラー: {e}")
        return {"error": str(e), "action": "analyzed"}


# 削除候補リソースの検出。実際の削除はRemediationAgentが承認後に実行
@tracer.capture_method
def get_unused_resources(params: dict) -> dict:
    resource_types = params.get("resource_types", ["EBS", "EIP"])

    results = []

    try:
        if "EBS" in resource_types:
            ebs_response = ec2_client.describe_volumes(
                Filters=[{"Name": "status", "Values": ["available"]}]
            )
            for vol in ebs_response.get("Volumes", []):
                size_gb = vol.get("Size", 0)
                # gp3の東京リージョン概算単価: $0.096/GB/月
                estimated_monthly_cost = round(size_gb * 0.096, 2)
                results.append(
                    {
                        "resource_id": vol["VolumeId"],
                        "resource_type": "EBS",
                        "size_gb": size_gb,
                        "volume_type": vol.get("VolumeType", ""),
                        "estimated_monthly_cost_usd": estimated_monthly_cost,
                        "created_at": vol.get("CreateTime", "").isoformat() if vol.get("CreateTime") else "",
                    }
                )

        if "EIP" in resource_types:
            eip_response = ec2_client.describe_addresses()
            for addr in eip_response.get("Addresses", []):
                if not addr.get("AssociationId"):
                    # 未使用EIPは約$0.005/時間 = $3.6/月
                    results.append(
                        {
                            "resource_id": addr.get("AllocationId", addr.get("PublicIp", "")),
                            "resource_type": "EIP",
                            "public_ip": addr.get("PublicIp", ""),
                            "estimated_monthly_cost_usd": 3.6,
                        }
                    )

        metrics.add_metric(name="UnusedResourcesFound", unit=MetricUnit.Count, value=len(results))
        return {"unused_resources": results, "total_count": len(results), "resource_types_checked": resource_types}

    except Exception as e:
        logger.error(f"未使用リソース検出エラー: {e}")
        return {"error": str(e), "action": "analyzed"}


@logger.inject_lambda_context
@tracer.capture_lambda_handler
@metrics.log_metrics
def lambda_handler(event: dict, context) -> dict:
    logger.info("コスト最適化Agent Action Group呼び出し", extra={"event": event})

    function_name = event.get("function", "")
    parameters = {p["name"]: p["value"] for p in event.get("parameters", [])}

    dispatch = {
        "get_cost_anomalies": get_cost_anomalies,
        "get_rightsizing_recommendations": get_rightsizing_recommendations,
        "get_unused_resources": get_unused_resources,
    }

    if function_name not in dispatch:
        result = {"error": f"不明な関数: {function_name}", "action": "analyzed"}
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
