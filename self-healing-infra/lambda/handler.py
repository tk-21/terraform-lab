import boto3
import json
import os
import urllib.request
import urllib.parse
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2', region_name='ap-northeast-1')

# あるべき状態（Ansible の allowed_ssh_cidrs と合わせる）
ALLOWED_SSH_CIDRS = ["10.0.0.0/8"]

def lambda_handler(event, context):
    """AWS Config の NON_COMPLIANT イベントを受け取り SG を修復する"""
    logger.info(f"Event: {json.dumps(event)}")

    detail      = event.get('detail', {})
    resource_id = detail.get('resourceId')  # 例: sg-xxxxxxxxxxxxxxxxx
    rule_name   = detail.get('configRuleName')

    if not resource_id:
        logger.error("No resourceId in event")
        return {'statusCode': 400}

    logger.info(f"NON_COMPLIANT: {rule_name} → {resource_id}")
    remediate_sg(resource_id)
    notify_chatwork(resource_id)

    return {'statusCode': 200, 'body': json.dumps({'remediated_sg': resource_id})}


def remediate_sg(sg_id: str):
    """全リセット → 正しいルール適用（Ansible の purge_rules: true と同じ考え方）"""
    resp = ec2.describe_security_groups(GroupIds=[sg_id])
    current_rules = resp['SecurityGroups'][0]['IpPermissions']

    # 全インバウンドルールを削除（リセット）
    if current_rules:
        ec2.revoke_security_group_ingress(GroupId=sg_id, IpPermissions=current_rules)
        logger.info(f"Revoked all inbound rules from {sg_id}")

    # あるべき状態のルールを適用
    ec2.authorize_security_group_ingress(
        GroupId=sg_id,
        IpPermissions=[{
            'IpProtocol': 'tcp',
            'FromPort': 22,
            'ToPort': 22,
            'IpRanges': [{'CidrIp': cidr, 'Description': 'Internal only'}
                         for cidr in ALLOWED_SSH_CIDRS]
        }]
    )
    logger.info(f"Applied compliant rules to {sg_id}")


def notify_chatwork(sg_id: str):
    """Chatwork に修復完了を通知する"""
    token   = os.environ['CHATWORK_API_TOKEN']
    room_id = os.environ['CHATWORK_ROOM_ID']
    message = (
        f"✅ [自己修復完了]\n"
        f"SG {sg_id} の不正ルールを自動削除しました\n"
        f"修復内容: 0.0.0.0/0 → port 22 を削除、内部 CIDR のみ許可"
    )
    data = urllib.parse.urlencode({'body': message}).encode()
    req  = urllib.request.Request(
        f"https://api.chatwork.com/v2/rooms/{room_id}/messages",
        data=data,
        headers={'X-ChatWorkToken': token},
        method='POST'
    )
    with urllib.request.urlopen(req) as res:
        logger.info(f"Chatwork notified: {res.status}")