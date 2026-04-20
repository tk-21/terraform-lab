"""
data-collector Lambda
FIS実験関連データをCloudWatch Logs/Metrics, CloudTrail, EKS Events から並列収集し、
bedrock-analyzerへ渡す構造化データを返す。

設計意図:
- concurrent.futuresで4ソースを並列収集（Lambda timeout 300秒対策）
- 障害開始時刻±5〜10分でフィルタしてBedrockへの入力を8,000トークン以下に収める
- IRSAでEKS APIサーバーへアクセス（kubeconfigファイル不使用）
"""

import base64
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone

import boto3
from aws_lambda_powertools import Logger, Tracer
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger()
tracer = Tracer()

CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "eks-chaos-postmortem-dev")
PROJECT_NAME = os.environ.get("PROJECT_NAME", "eks-chaos-postmortem-generator")

logs_client = boto3.client("logs")
cloudwatch_client = boto3.client("cloudwatch")
cloudtrail_client = boto3.client("cloudtrail")
eks_client = boto3.client("eks")

LOG_GROUP = f"/aws/eks/{CLUSTER_NAME}/cluster"
METRICS_NAMESPACE = "ContainerInsights"


@logger.inject_lambda_context
@tracer.capture_lambda_handler
def handler(event: dict, context: LambdaContext) -> dict:
    experiment_id = event["experiment_id"]
    experiment_type = event["experiment_type"]
    start_time_str = event["start_time"]
    end_time_str = event["end_time"]

    start_dt = _parse_datetime(start_time_str)
    end_dt = _parse_datetime(end_time_str)
    duration_seconds = int((end_dt - start_dt).total_seconds())

    logger.info("データ収集開始", experiment_id=experiment_id, experiment_type=experiment_type)

    collected_data = {
        "cloudwatch_logs": [],
        "metrics_summary": {},
        "cloudtrail_events": [],
        "k8s_events": [],
    }

    tasks = {
        "cloudwatch_logs": lambda: _collect_cloudwatch_logs(start_dt, end_dt),
        "metrics_summary": lambda: _collect_metrics(start_dt, end_dt),
        "cloudtrail_events": lambda: _collect_cloudtrail(start_dt, end_dt),
        "k8s_events": lambda: _collect_k8s_events(start_dt, end_dt),
    }

    with ThreadPoolExecutor(max_workers=4) as executor:
        futures = {executor.submit(fn): key for key, fn in tasks.items()}
        for future in as_completed(futures, timeout=240):
            key = futures[future]
            try:
                collected_data[key] = future.result(timeout=60)
                logger.info(f"{key}収集完了")
            except Exception as e:
                logger.warning(f"{key}収集エラー（スキップ）", error=str(e))

    result = {
        "experiment_id": experiment_id,
        "experiment_type": experiment_type,
        "start_time": start_time_str,
        "end_time": end_time_str,
        "duration_seconds": duration_seconds,
        "collected_data": collected_data,
        "data_collection_timestamp": datetime.now(timezone.utc).isoformat(),
    }

    logger.info("データ収集完了", experiment_id=experiment_id)
    return result


def _parse_datetime(dt_str: str) -> datetime:
    """ISO 8601文字列をdatetimeオブジェクトに変換する（末尾Zに対応）"""
    return datetime.fromisoformat(dt_str.replace("Z", "+00:00"))


def _collect_cloudwatch_logs(start_dt: datetime, end_dt: datetime) -> list:
    """CloudWatch Logsからエラー系ログを収集（障害前後5分、最大1,000行）"""
    filter_start = start_dt - timedelta(minutes=5)
    filter_end = end_dt + timedelta(minutes=5)

    logs = []
    try:
        paginator = logs_client.get_paginator("filter_log_events")
        pages = paginator.paginate(
            logGroupName=LOG_GROUP,
            startTime=int(filter_start.timestamp() * 1000),
            endTime=int(filter_end.timestamp() * 1000),
            filterPattern="?Error ?Warning ?OOMKill ?Evicted ?Failed",
            PaginationConfig={"MaxItems": 1000},
        )
        for page in pages:
            for event in page.get("events", []):
                logs.append({
                    "timestamp": event.get("timestamp"),
                    "message": event.get("message", "")[:500],
                })
    except Exception as e:
        logger.warning("CloudWatch Logs収集エラー", error=str(e))

    return logs[:1000]


def _collect_metrics(start_dt: datetime, end_dt: datetime) -> dict:
    """Container InsightsのCPU/Memoryメトリクスを収集（前後10分、60秒周期）"""
    metric_start = start_dt - timedelta(minutes=10)
    metric_end = end_dt + timedelta(minutes=10)

    metric_names = [
        "node_cpu_utilization",
        "node_memory_utilization",
        "pod_cpu_utilization",
        "pod_memory_utilization",
    ]

    summary = {}
    for metric_name in metric_names:
        try:
            response = cloudwatch_client.get_metric_statistics(
                Namespace=METRICS_NAMESPACE,
                MetricName=metric_name,
                Dimensions=[{"Name": "ClusterName", "Value": CLUSTER_NAME}],
                StartTime=metric_start,
                EndTime=metric_end,
                Period=60,
                Statistics=["Average", "Maximum"],
            )
            datapoints = response.get("Datapoints", [])
            if datapoints:
                summary[metric_name] = {
                    "avg": round(
                        sum(d["Average"] for d in datapoints) / len(datapoints), 2
                    ),
                    "max": round(max(d["Maximum"] for d in datapoints), 2),
                }
        except Exception as e:
            logger.warning(f"メトリクス収集エラー: {metric_name}", error=str(e))

    return summary


def _collect_cloudtrail(start_dt: datetime, end_dt: datetime) -> list:
    """CloudTrailからEKS/EC2/FIS関連APIコールを収集（前後5分、最大50件）"""
    filter_start = start_dt - timedelta(minutes=5)
    filter_end = end_dt + timedelta(minutes=5)

    events = []
    try:
        response = cloudtrail_client.lookup_events(
            StartTime=filter_start,
            EndTime=filter_end,
            MaxResults=50,
        )
        for event in response.get("Events", []):
            event_source = event.get("EventSource", "")
            # EKS/EC2/FIS関連のAPIコールのみフィルタ
            if any(svc in event_source for svc in ["eks", "ec2", "fis"]):
                event_time = event.get("EventTime")
                events.append({
                    "event_name": event.get("EventName", ""),
                    "event_source": event_source,
                    "event_time": event_time.isoformat() if hasattr(event_time, "isoformat") else str(event_time),
                    "username": event.get("Username", ""),
                })
    except Exception as e:
        logger.warning("CloudTrail収集エラー", error=str(e))

    return events[:50]


def _collect_k8s_events(start_dt: datetime, end_dt: datetime) -> list:
    """
    EKS APIサーバーからKubernetes Warningイベントを収集する。
    IRSAで取得したBearerトークンを使いchaos-target/kube-systemを対象とする。
    """
    try:
        from kubernetes import client as k8s_client

        # EKSクラスター情報取得（eks:DescribeClusterが必要）
        cluster_info = eks_client.describe_cluster(name=CLUSTER_NAME)["cluster"]
        endpoint = cluster_info["endpoint"]
        ca_data = cluster_info["certificateAuthority"]["data"]

        # STS presigned URLからEKS Bearer Tokenを生成
        token = _get_eks_bearer_token()

        # CA証明書を一時ファイルへ書き込む（kubernetes clientが証明書ファイルを要求するため）
        ca_bytes = base64.b64decode(ca_data)
        with tempfile.NamedTemporaryFile(delete=False, suffix=".crt") as ca_file:
            ca_file.write(ca_bytes)
            ca_path = ca_file.name

        configuration = k8s_client.Configuration()
        configuration.host = endpoint
        configuration.ssl_ca_cert = ca_path
        configuration.api_key = {"authorization": f"Bearer {token}"}
        k8s_client.Configuration.set_default(configuration)

        v1 = k8s_client.CoreV1Api()
        filter_start = start_dt - timedelta(minutes=10)
        filter_end = end_dt + timedelta(minutes=10)

        k8s_events = []
        for namespace in ["chaos-target", "kube-system"]:
            try:
                events = v1.list_namespaced_event(
                    namespace=namespace,
                    field_selector="type=Warning",
                )
                for ev in events.items:
                    event_time = ev.last_timestamp or ev.event_time
                    if event_time:
                        ev_dt = event_time.replace(tzinfo=timezone.utc) if event_time.tzinfo is None else event_time
                        if filter_start <= ev_dt <= filter_end:
                            k8s_events.append({
                                "namespace": namespace,
                                "reason": ev.reason or "",
                                "message": (ev.message or "")[:300],
                                "involved_object": ev.involved_object.name if ev.involved_object else "",
                                "event_time": str(event_time),
                            })
            except Exception as e:
                logger.warning(f"K8s Events収集エラー: {namespace}", error=str(e))

        return k8s_events

    except Exception as e:
        logger.warning("K8s Events収集全体エラー", error=str(e))
        return []


def _get_eks_bearer_token() -> str:
    """
    STS GetCallerIdentity presigned URLからEKS認証用Bearer Tokenを生成する。
    aws-iamを使ったIRSA認証の標準手法（kubeconfig不要）。
    """
    import botocore.auth
    import botocore.awsrequest

    session = boto3.session.Session()
    credentials = session.get_credentials().get_frozen_credentials()
    region = session.region_name or "ap-northeast-1"

    url = f"https://sts.{region}.amazonaws.com/?Action=GetCallerIdentity&Version=2011-06-15"
    request = botocore.awsrequest.AWSRequest(method="GET", url=url)
    request.headers["x-k8s-aws-id"] = CLUSTER_NAME

    signer = botocore.auth.SigV4QueryAuth(credentials, "sts", region, expires=60)
    signer.add_auth(request)

    signed_url = request.url
    token = "k8s-aws-v1." + base64.urlsafe_b64encode(signed_url.encode()).rstrip(b"=").decode()
    return token
