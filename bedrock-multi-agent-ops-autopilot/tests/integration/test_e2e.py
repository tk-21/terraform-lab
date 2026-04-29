"""
E2Eテスト: Multi-Agent Ops Autopilot

テストシナリオ:
1. コスト異常イベントをStep Functionsに直接投入
2. Supervisor Agentが起動することを確認
3. DynamoDB実行履歴にSUCCEEDEDが記録されることを確認（タイムアウト: 5分）
4. Chatwork通知の送信を確認（DynamoDBのstatus参照）
"""
import boto3
import json
import time
import uuid
import os
import sys
import pytest

REGION = "ap-northeast-1"
PREFIX = "bmao"
POLL_INTERVAL_SECONDS = 15
TIMEOUT_SECONDS = 300


def get_state_machine_arn() -> str:
    sfn = boto3.client("stepfunctions", region_name=REGION)
    paginator = sfn.get_paginator("list_state_machines")
    for page in paginator.paginate():
        for sm in page["stateMachines"]:
            if f"{PREFIX}-ops-orchestrator" in sm["name"]:
                return sm["stateMachineArn"]
    raise RuntimeError(f"{PREFIX}-ops-orchestrator が見つかりません")


def wait_for_execution(sfn_client, execution_arn: str, timeout: int = TIMEOUT_SECONDS) -> str:
    """実行完了までポーリングし、最終ステータスを返す"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        resp = sfn_client.describe_execution(executionArn=execution_arn)
        status = resp["status"]
        if status in ("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"):
            return status
        print(f"  実行中... status={status}")
        time.sleep(POLL_INTERVAL_SECONDS)
    return "TIMEOUT"


def get_dynamodb_status(execution_name: str) -> str | None:
    """DynamoDB実行履歴からステータスを取得"""
    ddb = boto3.client("dynamodb", region_name=REGION)
    try:
        resp = ddb.query(
            TableName=f"{PREFIX}-execution-history",
            KeyConditionExpression="execution_id = :eid",
            ExpressionAttributeValues={":eid": {"S": execution_name}},
        )
        if resp["Items"]:
            return resp["Items"][0].get("status", {}).get("S")
    except Exception as e:
        print(f"  DynamoDBクエリエラー: {e}")
    return None


def test_cost_anomaly_flow():
    """コスト異常イベントのE2Eフローテスト"""
    sfn_client = boto3.client("stepfunctions", region_name=REGION)
    state_machine_arn = get_state_machine_arn()

    execution_name = f"e2e-cost-{uuid.uuid4().hex[:8]}"
    test_input = {
        "event_type": "COST_ANOMALY",
        "event_detail": {
            "anomaly_id": "test-anomaly-001",
            "total_impact_usd": "55.00",
        },
    }

    print(f"\n[TEST] コスト異常フロー開始: execution_name={execution_name}")
    start_resp = sfn_client.start_execution(
        stateMachineArn=state_machine_arn,
        name=execution_name,
        input=json.dumps(test_input),
    )
    execution_arn = start_resp["executionArn"]
    print(f"  実行ARN: {execution_arn}")

    final_status = wait_for_execution(sfn_client, execution_arn)
    print(f"  Step Functions最終ステータス: {final_status}")

    assert final_status == "SUCCEEDED", f"Step Functions実行失敗: {final_status}"

    # DynamoDB記録を確認
    ddb_status = get_dynamodb_status(execution_name)
    print(f"  DynamoDBステータス: {ddb_status}")
    assert ddb_status == "SUCCEEDED", f"DynamoDB記録が期待値と異なる: {ddb_status}"

    print("[TEST] コスト異常フロー: PASS")


def test_cloudwatch_alarm_flow():
    """CloudWatchアラームイベントのE2Eフローテスト"""
    sfn_client = boto3.client("stepfunctions", region_name=REGION)
    state_machine_arn = get_state_machine_arn()

    execution_name = f"e2e-alarm-{uuid.uuid4().hex[:8]}"
    test_input = {
        "event_type": "CLOUDWATCH_ALARM",
        "event_detail": {
            "alarm_name": "test-high-cpu-alarm",
            "state": "ALARM",
            "reason": "Threshold Crossed: 1 datapoint > 80.0",
        },
    }

    print(f"\n[TEST] CloudWatchアラームフロー開始: execution_name={execution_name}")
    start_resp = sfn_client.start_execution(
        stateMachineArn=state_machine_arn,
        name=execution_name,
        input=json.dumps(test_input),
    )
    execution_arn = start_resp["executionArn"]
    print(f"  実行ARN: {execution_arn}")

    final_status = wait_for_execution(sfn_client, execution_arn)
    print(f"  Step Functions最終ステータス: {final_status}")

    assert final_status == "SUCCEEDED", f"Step Functions実行失敗: {final_status}"

    ddb_status = get_dynamodb_status(execution_name)
    print(f"  DynamoDBステータス: {ddb_status}")
    assert ddb_status == "SUCCEEDED", f"DynamoDB記録が期待値と異なる: {ddb_status}"

    print("[TEST] CloudWatchアラームフロー: PASS")


def test_execution_history_recorded():
    """実行履歴が正しくDynamoDBに記録されることを確認"""
    sfn_client = boto3.client("stepfunctions", region_name=REGION)
    ddb_client = boto3.client("dynamodb", region_name=REGION)
    state_machine_arn = get_state_machine_arn()

    execution_name = f"e2e-history-{uuid.uuid4().hex[:8]}"
    test_input = {
        "event_type": "COST_ANOMALY",
        "event_detail": {"anomaly_id": "test-history-001", "total_impact_usd": "60.00"},
    }

    start_resp = sfn_client.start_execution(
        stateMachineArn=state_machine_arn,
        name=execution_name,
        input=json.dumps(test_input),
    )
    execution_arn = start_resp["executionArn"]

    # 実行開始直後にRUNNING状態がDynamoDBに記録されていることを確認
    time.sleep(5)
    running_status = get_dynamodb_status(execution_name)
    assert running_status in ("RUNNING", "SUCCEEDED"), \
        f"RUNNING状態が記録されていない: {running_status}"

    wait_for_execution(sfn_client, execution_arn)

    final_status = get_dynamodb_status(execution_name)
    assert final_status == "SUCCEEDED", f"最終ステータスが不正: {final_status}"

    print("[TEST] 実行履歴記録確認: PASS")


if __name__ == "__main__":
    # 直接実行時はすべてのテストを順番に実行
    tests = [
        test_cost_anomaly_flow,
        test_cloudwatch_alarm_flow,
        test_execution_history_recorded,
    ]
    failed = []
    for test in tests:
        try:
            test()
        except Exception as e:
            print(f"[FAIL] {test.__name__}: {e}")
            failed.append(test.__name__)

    if failed:
        print(f"\n失敗したテスト: {failed}")
        sys.exit(1)
    print("\n全テスト PASS")
