"""
ドリフトスキャナー / AWS ConfigとCloudFormation Drift Detection APIを使って
実環境のリソース状態を取得するモジュール
"""

import json
import time


def get_cloudformation_drifts(cfn_client, stack_names: list) -> list:
    """
    CloudFormation Drift Detection APIを使って、指定スタックのドリフトリソースを取得する。

    Args:
        cfn_client: boto3 CloudFormationクライアント
        stack_names: 検査対象のスタック名リスト

    Returns:
        DRIFTEDリソースの情報リスト
    """
    drifted_resources = []

    for stack_name in stack_names:
        # ドリフト検知を開始してdetection_idを取得
        detect_response = cfn_client.detect_stack_drift(StackName=stack_name)
        detection_id = detect_response["StackDriftDetectionId"]

        # 最大60秒ポーリングしてDETECTION_COMPLETEを待つ
        elapsed = 0
        status = ""
        while elapsed < 60:
            status_response = cfn_client.describe_stack_drift_detection_status(
                StackDriftDetectionId=detection_id
            )
            status = status_response.get("DetectionStatus", "")
            if status == "DETECTION_COMPLETE":
                break
            # 5秒待機してから再チェック
            time.sleep(5)
            elapsed += 5

        # タイムアウトした場合は空リストを返す
        if status \!= "DETECTION_COMPLETE":
            return []

        # スタック自体がDRIFTEDの場合のみリソース一覧を取得
        stack_drift_status = status_response.get("StackDriftStatus", "")
        if stack_drift_status \!= "DRIFTED":
            continue

        # DRIFTEDリソースの一覧を取得（ページネーション対応）
        paginator = cfn_client.get_paginator("describe_stack_resource_drifts")
        page_iterator = paginator.paginate(
            StackName=stack_name,
            StackResourceDriftStatusFilters=["MODIFIED", "DELETED"],
        )

        for page in page_iterator:
            for resource in page.get("StackResourceDrifts", []):
                # expected_propertiesをJSONパース（存在しない場合は空dict）
                expected_raw = resource.get("ExpectedProperties", "{}")
                try:
                    expected_properties = json.loads(expected_raw)
                except (json.JSONDecodeError, TypeError):
                    expected_properties = {}

                # actual_propertiesをJSONパース（存在しない場合は空dict）
                actual_raw = resource.get("ActualProperties", "{}")
                try:
                    actual_properties = json.loads(actual_raw)
                except (json.JSONDecodeError, TypeError):
                    actual_properties = {}

                drifted_resources.append(
                    {
                        "stack_name": stack_name,
                        "resource_type": resource.get("ResourceType", ""),
                        "logical_id": resource.get("LogicalResourceId", ""),
                        "physical_id": resource.get("PhysicalResourceId", ""),
                        "drift_status": resource.get("StackResourceDriftStatus", ""),
                        "expected_properties": expected_properties,
                        "actual_properties": actual_properties,
                    }
                )

    return drifted_resources


def get_terraform_resources(s3_client, bucket: str, key: str) -> dict:
    """
    S3に保存されたtfstateファイルを取得し、managedリソースの情報を返す。

    Args:
        s3_client: boto3 S3クライアント
        bucket: tfstateが保存されているS3バケット名
        key: tfstateファイルのS3キー

    Returns:
        "{type}.{name}" をキーとするリソース情報のdict
    """
    # S3からtfstateを取得してJSONパース
    response = s3_client.get_object(Bucket=bucket, Key=key)
    tfstate_content = response["Body"].read().decode("utf-8")
    tfstate = json.loads(tfstate_content)

    tf_resources = {}

    # resourcesをループしてmanagedリソースのみ対象とする
    for resource in tfstate.get("resources", []):
        # managed以外（data等）はスキップ
        if resource.get("mode") \!= "managed":
            continue

        resource_type = resource.get("type", "")
        resource_name = resource.get("name", "")
        provider = resource.get("provider", "")

        # instances[0]["attributes"]があればそれを使用、なければ空dict
        instances = resource.get("instances", [])
        attributes = {}
        if instances:
            attributes = instances[0].get("attributes", {})

        # "{type}.{name}"をキーとして格納
        resource_key = f"{resource_type}.{resource_name}"
        tf_resources[resource_key] = {
            "type": resource_type,
            "name": resource_name,
            "provider": provider,
            "attributes": attributes,
        }

    return tf_resources
