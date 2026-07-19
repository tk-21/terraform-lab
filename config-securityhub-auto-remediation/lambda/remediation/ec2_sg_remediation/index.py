"""
Security Group自動修復Lambda
対応するConfig Rules:
  - csar-restricted-ssh  → 0.0.0.0/0:22 インバウンドルール削除
  - csar-restricted-rdp  → 0.0.0.0/0:3389 インバウンドルール削除

設計意図:
  - RevokeSecurityGroupIngressで違反ルールのみを削除する
  - SGの全ルールではなく、0.0.0.0/0 または ::/0 への該当ポートルールのみを削除
  - IPv6 (::/0) も対象にする
"""
import json
import os

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-remediation-ec2-sg")
tracer = Tracer(service="csar-remediation-ec2-sg")
metrics = Metrics(namespace="CSAR", service="sg-remediation")

ec2_client = boto3.client("ec2", region_name=os.environ.get("AWS_REGION", "ap-northeast-1"))

BLOCKED_PORTS = {22, 3389}  # SSH / RDP


def find_and_revoke_open_rules(sg_id: str) -> list[dict]:
    """
    SGの全インバウンドルールを検索し、
    0.0.0.0/0 または ::/0 へのSSH/RDPルールを削除する
    """
    resp = ec2_client.describe_security_groups(GroupIds=[sg_id])
    sg = resp["SecurityGroups"][0]

    rules_to_revoke = []
    revoked_summary = []

    for rule in sg.get("IpPermissions", []):
        from_port = rule.get("FromPort", -1)
        to_port = rule.get("ToPort", -1)

        # ポート範囲がブロック対象を含むかチェック
        target_ports = [p for p in BLOCKED_PORTS if from_port <= p <= to_port]
        if not target_ports:
            continue

        # IPv4 0.0.0.0/0 のチェック
        open_ipv4 = any(r.get("CidrIp") == "0.0.0.0/0" for r in rule.get("IpRanges", []))
        # IPv6 ::/0 のチェック
        open_ipv6 = any(r.get("CidrIpv6") == "::/0" for r in rule.get("Ipv6Ranges", []))

        if open_ipv4 or open_ipv6:
            rules_to_revoke.append(rule)
            revoked_summary.append({
                "ports": target_ports,
                "from_port": from_port,
                "to_port": to_port,
                "open_ipv4": open_ipv4,
                "open_ipv6": open_ipv6,
            })

    if rules_to_revoke:
        ec2_client.revoke_security_group_ingress(
            GroupId=sg_id,
            IpPermissions=rules_to_revoke,
        )
        logger.info("インバウンドルール削除完了", extra={"sg_id": sg_id, "revoked": revoked_summary})

    return revoked_summary


@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """SG修復Lambdaメインハンドラ"""
    logger.info("SG修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        detail_type = event.get("detail-type", "")
        trigger_source = (
            "CONFIG_RULE" if detail_type == "Config Rules Compliance Change"
            else "SECURITY_HUB_CUSTOM_ACTION"
        )

        if trigger_source == "CONFIG_RULE":
            sg_id = event["detail"]["resourceId"]
            rule_name = event["detail"]["configRuleName"]
        else:
            finding = event["detail"]["findings"][0]
            # SG ARN: arn:aws:ec2:region:account:security-group/sg-xxxxxx
            sg_id = finding["Resources"][0]["Id"].split("/")[-1]
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象SG", extra={"sg_id": sg_id, "rule_name": rule_name})

        revoked = find_and_revoke_open_rules(sg_id)
        if revoked:
            action = f"SSH/RDP全開放インバウンドルール削除: {len(revoked)}件"
        else:
            action = "削除対象ルールなし (既に修復済みの可能性)"

        record_remediation(
            remediation_id=remediation_id,
            resource_type="EC2-SG",
            resource_id=sg_id,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=action,
            status="SUCCESS",
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
            extra={"revoked_rules": revoked},
        )

        notify_remediation_result(
            resource_type="Security Group",
            resource_id=sg_id,
            rule_name=rule_name,
            remediation_action=action,
            status="SUCCESS",
            remediation_id=remediation_id,
            extra_info=f"削除ルール数: {len(revoked)}",
        )

        metrics.add_metric(name="RemediationSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="EC2-SG")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": "SUCCESS"}

    except Exception as e:
        logger.exception("SG修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
