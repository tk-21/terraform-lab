# Phase 4 — Lambda 自動修復関数実装 (S3 / IAM / EC2-SG / RDS)

## このフェーズの目的

4種のリソース修復Lambdaをフル実装する。
Config RuleトリガーとSecurity Hub Custom Actionトリガーの両方に対応し、
修復後にDynamoDB記録・S3監査ログ書き込み・Chatwork通知を行う。

## 前提確認

```bash
# Phase1-3のリソースが存在すること
aws dynamodb describe-table --table-name csar-remediation-log --query "Table.TableStatus"
aws sqs get-queue-url --queue-name csar-remediation-dlq
aws ssm get-parameter --name "/csar/chatwork/token" --with-decryption --query "Parameter.Value"
```

## ファイル構成

```
lambda/
├── shared/
│   ├── audit_logger.py       # DynamoDB + S3監査ログ (フル実装)
│   └── chatwork_notifier.py  # Chatwork通知 (フル実装)
└── remediation/
    ├── s3_remediation/
    │   ├── index.py
    │   └── requirements.txt
    ├── iam_remediation/
    │   ├── index.py
    │   └── requirements.txt
    ├── ec2_sg_remediation/
    │   ├── index.py
    │   └── requirements.txt
    └── rds_remediation/
        ├── index.py
        └── requirements.txt

terraform/modules/remediation/
├── lambda.tf       # Lambda関数 × 4 のTerraform定義
├── variables.tf
└── outputs.tf
```

---

## 1. 共通ライブラリ (フル実装)

### `lambda/shared/audit_logger.py`

```python
"""
監査ログ記録モジュール
DynamoDBへの修復ログ記録とS3への監査ログ保存を行う。

設計意図:
  - 修復IDで紐付け: DynamoDBとS3の両方に同じremeidiation_idで記録する
  - TTL付きDynamoDB: 90日後に自動削除されるためコスト管理が容易
  - S3は長期保管用 (Glacier移行あり)
  - 両方に書く理由: DynamoDBはクエリ用、S3はコンプライアンス証跡用
"""
import json
import os
import time
import uuid
from datetime import datetime, timezone, timedelta
from typing import Optional

import boto3
from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities.typing import LambdaContext

logger = Logger(service="csar-audit-logger")

# JSTタイムゾーン定義
JST = timezone(timedelta(hours=9))

# 環境変数 (Terraformで設定)
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE_NAME"]
AUDIT_BUCKET = os.environ["AUDIT_BUCKET_NAME"]
REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

_dynamodb = None
_s3 = None

def _get_dynamodb():
    """DynamoDBクライアントのシングルトン取得 (コールドスタート最適化)"""
    global _dynamodb
    if _dynamodb is None:
        _dynamodb = boto3.resource("dynamodb", region_name=REGION)
    return _dynamodb

def _get_s3():
    """S3クライアントのシングルトン取得"""
    global _s3
    if _s3 is None:
        _s3 = boto3.client("s3", region_name=REGION)
    return _s3

def generate_remediation_id() -> str:
    """修復IDを生成する: csar-rem-YYYYMMDD-uuid8形式"""
    today = datetime.now(JST).strftime("%Y%m%d")
    short_uuid = str(uuid.uuid4())[:8]
    return f"csar-rem-{today}-{short_uuid}"

def _calc_ttl_epoch(days: int = 90) -> int:
    """DynamoDB TTL用のエポック秒を計算する (デフォルト90日後)"""
    return int((datetime.now(timezone.utc) + timedelta(days=days)).timestamp())

def record_remediation(
    remediation_id: str,
    resource_type: str,       # "S3" / "IAM" / "EC2-SG" / "RDS"
    resource_id: str,         # バケット名/ユーザー名/SG-ID/DB識別子
    rule_name: str,           # Config Rule名
    violation_detail: dict,   # 違反の詳細情報
    remediation_action: str,  # 実行した修復内容の説明
    status: str,              # "SUCCESS" / "FAILED" / "MANUAL_REQUIRED"
    trigger_source: str,      # "CONFIG_RULE" / "SECURITY_HUB_CUSTOM_ACTION"
    aws_account_id: str,
    region: str = "ap-northeast-1",
    extra: Optional[dict] = None,  # リソース固有の追加情報
) -> None:
    """修復ログをDynamoDB + S3に記録する"""
    now_jst = datetime.now(JST)
    timestamp = now_jst.isoformat()

    # DynamoDBへの記録データ
    item = {
        "remediation_id": remediation_id,
        "timestamp": timestamp,
        "resource_type": resource_type,
        "resource_id": resource_id,
        "rule_name": rule_name,
        "violation_detail": json.dumps(violation_detail, ensure_ascii=False),
        "remediation_action": remediation_action,
        "status": status,
        "trigger_source": trigger_source,
        "aws_account_id": aws_account_id,
        "region": region,
        "ttl": _calc_ttl_epoch(days=90),
    }
    if extra:
        item["extra"] = json.dumps(extra, ensure_ascii=False)

    # DynamoDB PutItem
    try:
        table = _get_dynamodb().Table(DYNAMODB_TABLE)
        table.put_item(Item=item)
        logger.info("DynamoDB修復ログ記録成功", extra={"remediation_id": remediation_id})
    except Exception as e:
        # ログ記録失敗はメイン処理を止めない (ベストエフォート)
        logger.error("DynamoDB記録エラー", extra={"error": str(e), "remediation_id": remediation_id})

    # S3へのJSONログ保存
    # キー: remediation-logs/year=YYYY/month=MM/day=DD/{remediation_id}.json
    s3_key = (
        f"remediation-logs/"
        f"year={now_jst.strftime('%Y')}/"
        f"month={now_jst.strftime('%m')}/"
        f"day={now_jst.strftime('%d')}/"
        f"{remediation_id}.json"
    )
    try:
        _get_s3().put_object(
            Bucket=AUDIT_BUCKET,
            Key=s3_key,
            Body=json.dumps(item, ensure_ascii=False, indent=2),
            ContentType="application/json",
            ServerSideEncryption="AES256",
        )
        logger.info("S3監査ログ書き込み成功", extra={"s3_key": s3_key})
    except Exception as e:
        logger.error("S3書き込みエラー", extra={"error": str(e), "s3_key": s3_key})
```

### `lambda/shared/chatwork_notifier.py`

```python
"""
Chatwork通知モジュール
修復結果をChatwork REST APIで通知する。

設計意図:
  - SSMから毎回取得するのではなくキャッシュを使う (Lambda実行コンテキスト再利用)
  - urllib.requestを使い外部ライブラリ依存をなくす
  - 通知失敗は修復結果に影響させない (ベストエフォート)
"""
import os
import urllib.request
import urllib.parse
from typing import Optional

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="csar-chatwork-notifier")

REGION = os.environ.get("AWS_REGION", "ap-northeast-1")

# SSMからの取得結果をキャッシュ (Lambda実行コンテキスト再利用のため)
_chatwork_token: Optional[str] = None
_chatwork_room_id: Optional[str] = None

def _get_chatwork_credentials() -> tuple[str, str]:
    """SSM Parameter StoreからChatwork認証情報を取得する (キャッシュあり)"""
    global _chatwork_token, _chatwork_room_id

    if _chatwork_token and _chatwork_room_id:
        return _chatwork_token, _chatwork_room_id

    ssm = boto3.client("ssm", region_name=REGION)
    # WithDecryption=True: SecureString型パラメータの復号に必要
    token_resp = ssm.get_parameter(Name="/csar/chatwork/token", WithDecryption=True)
    room_resp = ssm.get_parameter(Name="/csar/chatwork/room_id", WithDecryption=True)

    _chatwork_token = token_resp["Parameter"]["Value"]
    _chatwork_room_id = room_resp["Parameter"]["Value"]

    return _chatwork_token, _chatwork_room_id

def _build_message(
    resource_type: str,
    resource_id: str,
    rule_name: str,
    remediation_action: str,
    status: str,
    remediation_id: str,
    extra_info: Optional[str] = None,
) -> str:
    """Chatwork通知メッセージを構築する"""
    status_label = {
        "SUCCESS": "[修復成功] ✅",
        "FAILED": "[修復失敗 / 要確認] ❌",
        "MANUAL_REQUIRED": "[手動対応が必要] ⚠️",
    }.get(status, f"[{status}]")

    lines = [
        f"{status_label}",
        f"リソース種別: {resource_type}",
        f"リソースID: {resource_id}",
        f"違反ルール: {rule_name}",
        f"修復内容: {remediation_action}",
        f"修復ID: {remediation_id}",
    ]
    if extra_info:
        lines.append(f"追加情報: {extra_info}")

    return "\n".join(lines)

def notify_remediation_result(
    resource_type: str,
    resource_id: str,
    rule_name: str,
    remediation_action: str,
    status: str,
    remediation_id: str,
    extra_info: Optional[str] = None,
) -> None:
    """修復結果をChatworkに通知する"""
    try:
        token, room_id = _get_chatwork_credentials()
    except Exception as e:
        # SSM取得失敗は通知をスキップ (修復結果には影響させない)
        logger.error("Chatwork認証情報取得失敗", extra={"error": str(e)})
        return

    message = _build_message(
        resource_type=resource_type,
        resource_id=resource_id,
        rule_name=rule_name,
        remediation_action=remediation_action,
        status=status,
        remediation_id=remediation_id,
        extra_info=extra_info,
    )

    try:
        url = f"https://api.chatwork.com/v2/rooms/{room_id}/messages"
        data = urllib.parse.urlencode({"body": message}).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "X-ChatWorkToken": token,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            logger.info("Chatwork通知成功", extra={"status_code": resp.status})
    except Exception as e:
        # 通知失敗はベストエフォート (修復済みなので致命的エラーにしない)
        logger.error("Chatwork通知エラー", extra={"error": str(e)})
```

---

## 2. S3 修復 Lambda

### `lambda/remediation/s3_remediation/index.py`

```python
"""
S3バケット自動修復Lambda
対応するConfig Rules:
  - csar-s3-bucket-public-read-prohibited   → Block Public Access を有効化
  - csar-s3-bucket-server-side-encryption-enabled → AES256 SSE を設定

トリガー:
  - Config Rules Compliance Change (自動)
  - Security Hub Findings - Custom Action (手動)
"""
import json
import os
import sys

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

# 共有モジュールのパスを追加
sys.path.insert(0, "/opt/python")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "shared"))

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-s3-remediation")
tracer = Tracer(service="csar-s3-remediation")
metrics = Metrics(namespace="CSAR", service="s3-remediation")

s3_client = boto3.client("s3", region_name="ap-northeast-1")

# リソースタイプ変換テーブル
# Config Rule → AWS::S3::Bucket
# Security Hub Custom Action → AwsS3Bucket
RESOURCE_TYPE_MAP = {
    "AWS::S3::Bucket": "S3",
    "AwsS3Bucket": "S3",
}

def detect_trigger_source(event: dict) -> str:
    """イベントのトリガー元を判定する"""
    detail_type = event.get("detail-type", "")
    if detail_type == "Config Rules Compliance Change":
        return "CONFIG_RULE"
    elif detail_type == "Security Hub Findings - Custom Action":
        return "SECURITY_HUB_CUSTOM_ACTION"
    else:
        raise ValueError(f"未知のトリガー種別: {detail_type}")

def extract_resource_info_from_config(event: dict) -> tuple[str, str]:
    """Config Ruleイベントからリソース情報を抽出する"""
    detail = event["detail"]
    bucket_name = detail["resourceId"]
    rule_name = detail["configRuleName"]
    return bucket_name, rule_name

def extract_resource_info_from_custom_action(event: dict) -> tuple[str, str]:
    """Security Hub Custom Actionイベントからリソース情報を抽出する"""
    findings = event["detail"]["findings"]
    finding = findings[0]
    # Security HubのResourceIdはARN形式: arn:aws:s3:::bucket-name
    resource_arn = finding["Resources"][0]["Id"]
    bucket_name = resource_arn.split(":::")[-1]  # ARNからバケット名を抽出
    rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")
    return bucket_name, rule_name

def remediate_public_access_block(bucket_name: str) -> dict:
    """S3バケットのBlock Public Accessを有効化する"""
    s3_client.put_public_access_block(
        Bucket=bucket_name,
        PublicAccessBlockConfiguration={
            "BlockPublicAcls": True,
            "IgnorePublicAcls": True,
            "BlockPublicPolicy": True,
            "RestrictPublicBuckets": True,
        },
    )
    return {
        "action": "Block Public Access 有効化",
        "details": "BlockPublicAcls/IgnorePublicAcls/BlockPublicPolicy/RestrictPublicBuckets を全てtrue に設定",
    }

def remediate_sse(bucket_name: str) -> dict:
    """S3バケットにAES256 SSEを設定する"""
    s3_client.put_bucket_encryption(
        Bucket=bucket_name,
        ServerSideEncryptionConfiguration={
            "Rules": [
                {
                    "ApplyServerSideEncryptionByDefault": {
                        "SSEAlgorithm": "AES256",
                    },
                    "BucketKeyEnabled": True,  # S3 Bucket Keyでコスト削減
                }
            ]
        },
    )
    return {
        "action": "SSE-S3 (AES256) 暗号化設定",
        "details": "BucketKeyEnabled=trueでKMSリクエストコストを削減",
    }

@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """S3修復Lambdaメインハンドラ"""
    logger.info("S3修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        trigger_source = detect_trigger_source(event)

        # トリガー元に応じてリソース情報を抽出
        if trigger_source == "CONFIG_RULE":
            bucket_name, rule_name = extract_resource_info_from_config(event)
        else:
            bucket_name, rule_name = extract_resource_info_from_custom_action(event)

        logger.info("修復対象", extra={
            "bucket_name": bucket_name,
            "rule_name": rule_name,
            "trigger": trigger_source,
        })

        # ルール名に応じた修復アクション選択
        result = {}
        if "public-read-prohibited" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            # Public Access Block修復 (Custom Actionの場合は両方実行)
            result.update(remediate_public_access_block(bucket_name))

        if "server-side-encryption" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            # SSE修復
            result.update(remediate_sse(bucket_name))

        remediation_action = result.get("action", "修復実行")

        # 成功記録
        record_remediation(
            remediation_id=remediation_id,
            resource_type="S3",
            resource_id=bucket_name,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=remediation_action,
            status="SUCCESS",
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        # Chatwork通知
        notify_remediation_result(
            resource_type="S3バケット",
            resource_id=bucket_name,
            rule_name=rule_name,
            remediation_action=remediation_action,
            status="SUCCESS",
            remediation_id=remediation_id,
        )

        # CloudWatch カスタムメトリクス (EMF)
        metrics.add_metric(name="RemediationSuccess", unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="S3")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": "SUCCESS"}

    except Exception as e:
        logger.exception("S3修復エラー", extra={"error": str(e)})
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)

        # 失敗記録
        record_remediation(
            remediation_id=remediation_id,
            resource_type="S3",
            resource_id=event.get("detail", {}).get("resourceId", "UNKNOWN"),
            rule_name=event.get("detail", {}).get("configRuleName", "UNKNOWN"),
            violation_detail=event.get("detail", {}),
            remediation_action="修復失敗",
            status="FAILED",
            trigger_source=event.get("detail-type", "UNKNOWN"),
            aws_account_id=aws_account_id,
            extra={"error": str(e)},
        )

        # DLQへ自動的に転送されるようにraiseする
        raise
```

### `lambda/remediation/s3_remediation/requirements.txt`

```
aws-lambda-powertools[all]==2.37.0
boto3>=1.34.0
```

---

## 3. IAM 修復 Lambda

### `lambda/remediation/iam_remediation/index.py`

```python
"""
IAMユーザー自動修復Lambda
対応するConfig Rules:
  - csar-iam-user-mfa-enabled     → コンソールアクセス無効化 + Chatwork警告
  - csar-iam-user-no-policies-check → 直接アタッチポリシーをChatworkで警告

設計意図:
  - MFA未設定ユーザーのコンソールアクセスを無効化する (ログインプロファイル削除)
  - IAMポリシーの直接アタッチはインプレースでは修復せず、通知のみ
    (どのポリシーをどのグループに移すかは人間が判断すべき)
"""
import json
import os
import sys

import boto3
from botocore.exceptions import ClientError
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "shared"))

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-iam-remediation")
tracer = Tracer(service="csar-iam-remediation")
metrics = Metrics(namespace="CSAR", service="iam-remediation")

iam_client = boto3.client("iam", region_name="ap-northeast-1")

def check_user_has_mfa(username: str) -> bool:
    """ユーザーがMFAデバイスを持っているか確認する"""
    resp = iam_client.list_mfa_devices(UserName=username)
    return len(resp["MFADevices"]) > 0

def disable_console_access(username: str) -> dict:
    """
    IAMユーザーのコンソールアクセスを無効化する
    コンソールアクセス = LoginProfile の存在
    削除することでパスワードログイン不可になる
    """
    try:
        iam_client.delete_login_profile(UserName=username)
        return {
            "action": "コンソールアクセス無効化 (LoginProfile削除)",
            "status": "SUCCESS",
        }
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            # すでにLoginProfileがない場合 (プログラムアクセスのみユーザー)
            return {
                "action": "LoginProfile未存在のためスキップ",
                "status": "SUCCESS",
            }
        raise

def remediate_mfa_not_enabled(username: str) -> tuple[str, str]:
    """MFA未設定ユーザーの修復を実行する"""
    has_mfa = check_user_has_mfa(username)

    if has_mfa:
        # MFAデバイスはあるが有効化されていない状態 (稀なケース)
        return "MFAデバイス登録済みだがConfig Rule再評価が必要", "MANUAL_REQUIRED"

    # MFA未設定: コンソールアクセス無効化
    result = disable_console_access(username)
    return result["action"], result["status"]

def remediate_inline_policy(username: str) -> tuple[str, str]:
    """直接アタッチポリシーの修復 (通知のみ)"""
    resp = iam_client.list_attached_user_policies(UserName=username)
    policies = [p["PolicyName"] for p in resp["AttachedPolicies"]]

    action = (
        f"直接アタッチポリシーの手動移行が必要: {', '.join(policies)}"
        if policies
        else "直接アタッチポリシーなし (再評価が必要)"
    )
    return action, "MANUAL_REQUIRED"

@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """IAM修復Lambdaメインハンドラ"""
    logger.info("IAM修復Lambda開始", extra={"event": json.dumps(event)})

    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        detail_type = event.get("detail-type", "")
        trigger_source = (
            "CONFIG_RULE" if detail_type == "Config Rules Compliance Change"
            else "SECURITY_HUB_CUSTOM_ACTION"
        )

        # リソース情報抽出
        if trigger_source == "CONFIG_RULE":
            username = event["detail"]["resourceId"]
            rule_name = event["detail"]["configRuleName"]
        else:
            finding = event["detail"]["findings"][0]
            username = finding["Resources"][0]["Id"].split("/")[-1]  # ARNからユーザー名
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象IAMユーザー", extra={"username": username, "rule_name": rule_name})

        # ルールに応じた修復
        if "mfa-enabled" in rule_name or trigger_source == "SECURITY_HUB_CUSTOM_ACTION":
            action, status = remediate_mfa_not_enabled(username)
        else:  # no-policies-check
            action, status = remediate_inline_policy(username)

        # 記録・通知
        record_remediation(
            remediation_id=remediation_id,
            resource_type="IAM",
            resource_id=username,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=action,
            status=status,
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        notify_remediation_result(
            resource_type="IAMユーザー",
            resource_id=username,
            rule_name=rule_name,
            remediation_action=action,
            status=status,
            remediation_id=remediation_id,
        )

        metrics.add_metric(
            name="RemediationSuccess" if status == "SUCCESS" else "RemediationManualRequired",
            unit=MetricUnit.Count,
            value=1,
        )
        metrics.add_metadata(key="resource_type", value="IAM")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": status}

    except Exception as e:
        logger.exception("IAM修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
```

---

## 4. EC2/SG 修復 Lambda

### `lambda/remediation/ec2_sg_remediation/index.py`

```python
"""
Security Group自動修復Lambda
対応するConfig Rules:
  - csar-restricted-ssh  → 0.0.0.0/0:22 インバウンドルール削除
  - csar-restricted-rdp  → 0.0.0.0/0:3389 インバウンドルール削除

設計意図:
  - RevokeSecurityGroupIngressで該当ルールのみを削除する
  - SGのすべてのルールを削除するのではなく、違反ルールのみを削除する
  - IPv6 (::/0) も対象にする
"""
import json
import os
import sys

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "shared"))

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-sg-remediation")
tracer = Tracer(service="csar-sg-remediation")
metrics = Metrics(namespace="CSAR", service="sg-remediation")

ec2_client = boto3.client("ec2", region_name="ap-northeast-1")

BLOCKED_PORTS = {22, 3389}  # SSH / RDP

def find_and_revoke_open_rules(sg_id: str) -> list[dict]:
    """
    SGの全インバウンドルールを検索し、
    0.0.0.0/0 または ::/0 へのSSH/RDPルールを削除する
    """
    resp = ec2_client.describe_security_groups(GroupIds=[sg_id])
    sg = resp["SecurityGroups"][0]

    revoked_rules = []
    rules_to_revoke = []

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
            revoked_rules.append({
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
        logger.info("インバウンドルール削除完了", extra={"sg_id": sg_id, "revoked": revoked_rules})
    else:
        logger.info("削除対象ルールなし (既に修復済みの可能性)", extra={"sg_id": sg_id})

    return revoked_rules

@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """SG修復Lambdaメインハンドラ"""
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
            sg_id = finding["Resources"][0]["Id"].split("/")[-1]
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象SG", extra={"sg_id": sg_id})

        revoked = find_and_revoke_open_rules(sg_id)
        action = (
            f"SSH/RDP開放インバウンドルール削除: {len(revoked)}件"
            if revoked
            else "削除対象ルールなし (再評価が必要)"
        )

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

        return {"statusCode": 200, "remediation_id": remediation_id}

    except Exception as e:
        logger.exception("SG修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
```

---

## 5. RDS 修復 Lambda

### `lambda/remediation/rds_remediation/index.py`

```python
"""
RDS自動修復Lambda
対応するConfig Rules:
  - csar-rds-storage-encrypted        → スナップショット取得 + 手動対応通知
  - csar-rds-instance-public-access-check → PubliclyAccessible=false に変更

設計意図:
  - RDSの暗号化はインプレースで変更不可 (DBを再作成する必要がある)
  - そのためスナップショットを取得してChatworkで通知し、手動対応を促す
  - PubliclyAccessibleはModifyDBInstanceで変更可能 (即時修復できる)
"""
import json
import os
import sys
from datetime import datetime, timezone, timedelta

import boto3
from aws_lambda_powertools import Logger, Tracer, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from aws_lambda_powertools.utilities.typing import LambdaContext

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "shared"))

from audit_logger import generate_remediation_id, record_remediation
from chatwork_notifier import notify_remediation_result

logger = Logger(service="csar-rds-remediation")
tracer = Tracer(service="csar-rds-remediation")
metrics = Metrics(namespace="CSAR", service="rds-remediation")

rds_client = boto3.client("rds", region_name="ap-northeast-1")

JST = timezone(timedelta(hours=9))

def remediate_public_access(db_identifier: str) -> tuple[str, str]:
    """RDS PubliclyAccessibleをfalseに変更する (即時修復可能)"""
    rds_client.modify_db_instance(
        DBInstanceIdentifier=db_identifier,
        PubliclyAccessible=False,
        ApplyImmediately=True,  # メンテナンスウィンドウを待たず即時適用
    )
    return "PubliclyAccessible=false に変更 (ApplyImmediately=true)", "SUCCESS"

def remediate_encryption_not_enabled(db_identifier: str) -> tuple[str, str]:
    """
    RDS暗号化なしの修復
    インプレース変更は不可のため、スナップショットを取得して通知する。
    実際の移行手順:
      1. スナップショット取得 (このLambdaで実施)
      2. スナップショットから暗号化済み新DBを復元 (手動)
      3. 旧DBの削除 (手動、データ移行確認後)
    """
    snapshot_id = f"csar-snap-{db_identifier[:20]}-{datetime.now(JST).strftime('%Y%m%d%H%M')}"
    # snapshot_idは255文字制限、英数字とハイフンのみ
    snapshot_id = snapshot_id[:255]

    rds_client.create_db_snapshot(
        DBSnapshotIdentifier=snapshot_id,
        DBInstanceIdentifier=db_identifier,
        Tags=[
            {"Key": "CreatedBy", "Value": "csar-auto-remediation"},
            {"Key": "Reason", "Value": "encryption-not-enabled"},
        ],
    )

    action = (
        f"暗号化なしRDSのスナップショット取得: {snapshot_id}\n"
        "暗号化済みDBへの移行は手動で実施してください。\n"
        "手順: スナップショット→暗号化復元→エンドポイント切り替え→旧DB削除"
    )
    return action, "MANUAL_REQUIRED"

@tracer.capture_lambda_handler
@logger.inject_lambda_context
@metrics.log_metrics(capture_cold_start_metric=True)
def handler(event: dict, context: LambdaContext) -> dict:
    """RDS修復Lambdaメインハンドラ"""
    remediation_id = generate_remediation_id()
    aws_account_id = context.invoked_function_arn.split(":")[4]

    try:
        detail_type = event.get("detail-type", "")
        trigger_source = (
            "CONFIG_RULE" if detail_type == "Config Rules Compliance Change"
            else "SECURITY_HUB_CUSTOM_ACTION"
        )

        if trigger_source == "CONFIG_RULE":
            db_identifier = event["detail"]["resourceId"]
            rule_name = event["detail"]["configRuleName"]
        else:
            finding = event["detail"]["findings"][0]
            resource_id = finding["Resources"][0]["Id"]
            # RDSのARN形式: arn:aws:rds:region:account:db:identifier
            db_identifier = resource_id.split(":")[-1]
            rule_name = finding.get("GeneratorId", "SECURITY_HUB_CUSTOM_ACTION")

        logger.info("修復対象RDS", extra={"db_identifier": db_identifier})

        if "public-access-check" in rule_name:
            action, status = remediate_public_access(db_identifier)
        else:  # storage-encrypted
            action, status = remediate_encryption_not_enabled(db_identifier)

        record_remediation(
            remediation_id=remediation_id,
            resource_type="RDS",
            resource_id=db_identifier,
            rule_name=rule_name,
            violation_detail=event.get("detail", {}),
            remediation_action=action,
            status=status,
            trigger_source=trigger_source,
            aws_account_id=aws_account_id,
        )

        notify_remediation_result(
            resource_type="RDS DBインスタンス",
            resource_id=db_identifier,
            rule_name=rule_name,
            remediation_action=action,
            status=status,
            remediation_id=remediation_id,
        )

        metric_name = "RemediationSuccess" if status == "SUCCESS" else "RemediationManualRequired"
        metrics.add_metric(name=metric_name, unit=MetricUnit.Count, value=1)
        metrics.add_metadata(key="resource_type", value="RDS")

        return {"statusCode": 200, "remediation_id": remediation_id, "status": status}

    except Exception as e:
        logger.exception("RDS修復エラー")
        metrics.add_metric(name="RemediationFailed", unit=MetricUnit.Count, value=1)
        raise
```

---

## 6. Lambda Terraform定義

**ファイル**: `terraform/modules/remediation/lambda.tf`

```hcl
# Lambda Layer (共有モジュール配布用)
# shared/ ディレクトリをLayerとしてパッケージングしてLambdaに配布する
resource "aws_lambda_layer_version" "csar_shared" {
  layer_name          = "csar-shared-modules"
  filename            = "${path.module}/../../../lambda/shared.zip"
  compatible_runtimes = ["python3.12"]
  compatible_architectures = ["arm64"]

  description = "CSAR共有モジュール: audit_logger + chatwork_notifier"
}

# S3修復Lambda
resource "aws_lambda_function" "s3_remediation" {
  function_name = "csar-s3-remediation"
  role          = var.lambda_role_arn
  handler       = "index.handler"
  runtime       = "python3.12"
  architectures = ["arm64"]  # Graviton2: コスト20%削減
  timeout       = 300
  memory_size   = 256

  filename         = "${path.module}/../../../lambda/remediation/s3_remediation.zip"
  source_code_hash = filebase64sha256("${path.module}/../../../lambda/remediation/s3_remediation.zip")

  layers = [aws_lambda_layer_version.csar_shared.arn]

  # VPC内で実行 (VPC Endpoint経由でAWS APIを呼ぶため)
  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [var.lambda_sg_id]
  }

  environment {
    variables = {
      DYNAMODB_TABLE_NAME = var.dynamodb_table_name
      AUDIT_BUCKET_NAME   = var.audit_bucket_name
      POWERTOOLS_SERVICE_NAME = "csar-s3-remediation"
      LOG_LEVEL           = "INFO"
    }
  }

  # DLQ: 3回リトライ失敗後にSQS DLQへ転送
  dead_letter_config {
    target_arn = var.dlq_arn
  }

  reserved_concurrent_executions = 10  # 暴走防止

  tracing_config {
    mode = "Active"  # X-Ray有効化
  }

  tags = var.common_tags
}

# Lambda の EventBridge 呼び出し許可
resource "aws_lambda_permission" "s3_config_rule" {
  statement_id  = "AllowEventBridgeConfigRule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.s3_config_rule_event_rule_arn
}

resource "aws_lambda_permission" "s3_custom_action" {
  statement_id  = "AllowEventBridgeCustomAction"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.s3_remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = var.s3_custom_action_event_rule_arn
}

# IAM / EC2-SG / RDS も同様のパターンで定義 (省略: 同構造を繰り返す)
# aws_lambda_function.iam_remediation
# aws_lambda_function.sg_remediation
# aws_lambda_function.rds_remediation
```

`terraform/modules/remediation/outputs.tf`:
```hcl
output "s3_remediation_lambda_arn"  { value = aws_lambda_function.s3_remediation.arn }
output "iam_remediation_lambda_arn" { value = aws_lambda_function.iam_remediation.arn }
output "sg_remediation_lambda_arn"  { value = aws_lambda_function.sg_remediation.arn }
output "rds_remediation_lambda_arn" { value = aws_lambda_function.rds_remediation.arn }
```

## 実行手順

```bash
# 1. 共有モジュールのZip化
cd lambda/shared
zip -r ../shared.zip .

# 2. 各Lambda関数のZip化
for func in s3 iam ec2_sg rds; do
  cd lambda/remediation/${func}_remediation
  pip install -r requirements.txt -t package/ --platform manylinux2014_aarch64 --only-binary=:all:
  cd package && zip -r ../../${func}_remediation.zip .
  cd .. && zip -g ../../${func}_remediation.zip index.py
done

# 3. Phase2のEventBridgeターゲットARNを更新してapply
# modules/config/eventbridge.tf の var.xxx_remediation_lambda_arn を
# module.remediation.xxx_remediation_lambda_arn に更新する

terraform apply
```

## 口頭説明チェック (Phase 4)

以下を見ずに説明できるか確認すること:

1. **Lambda Layerを使う理由** — 共有モジュールを各Lambdaにコピーせず Layerで配布する利点は？デプロイパッケージサイズとコールドスタートへの影響は？

2. **arm64 (Graviton2) をLambdaに使う理由** — x86_64との価格差と性能差、および `--platform manylinux2014_aarch64` でビルドする必要がある理由は？

3. **RDSの暗号化をインプレースで修復できない技術的理由** — AWSがRDS暗号化のインプレース変更をサポートしていない理由と、スナップショットから暗号化済みDBを復元する手順を説明できるか？

4. **Lambda の reserved_concurrent_executions=10 の意味** — これがないと何が起きるか？セキュリティ自動修復の文脈でなぜ暴走防止が重要か？

5. **DLQ と raise の関係** — Lambdaが例外をraiseしないとDLQにメッセージが転送されない理由と、べき等性設計（同じ修復を2回実行しても安全か）の考え方は？