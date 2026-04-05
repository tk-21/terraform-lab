"""
reliability-reviewer エージェント

役割:
    AWS インフラ（Terraform コードまたはアーキテクチャ図の説明）を
    可用性・信頼性観点からレビューする専門エージェント。

チェック観点:
    - Single AZ 構成のリスク（マルチ AZ での冗長化推奨）
    - バックアップ設定（RDS 自動バックアップ・DynamoDB PITR）
    - フェイルオーバー設定（RDS Multi-AZ・Route53 ヘルスチェック）
    - RPO / RTO の設計考慮（目標復旧時点・時間の達成可能性）
    - オートスケーリング設定（ECS/ASG の設定確認）
    - ヘルスチェックと自動復旧（ALB ターゲットグループ・CloudWatch Alarm）

出力形式（CLAUDE.md 定義の JSON 統一形式）:
    {
        "agent": "reliability",
        "findings": [...],
        "score": 0-100,
        "summary": "全体所見（2文以内）"
    }
"""

import json
import os
import logging
import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")
dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")

TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
MODEL_ID = os.environ["BEDROCK_MODEL_ID"]
AGENT_NAME = os.environ["AGENT_NAME"]

# =============================================================================
# システムプロンプト
# 可用性・信頼性観点でのレビュー観点・出力形式を定義
# =============================================================================
SYSTEM_PROMPT = """あなたは AWS インフラの可用性・信頼性設計の専門家です。
Terraform コードまたはアーキテクチャ構成を受け取り、障害耐性と復旧能力を評価してください。

## チェック観点（必ず全項目を確認すること）

1. **マルチ AZ 構成**
   - データベース（RDS, ElastiCache）がマルチ AZ 構成になっているか
   - ALB/NLB が複数 AZ にわたってターゲットを持っているか
   - Lambda / ECS は複数 AZ で実行されているか（コンテナの場合）
   - Single AZ 構成のリソースは意図的なものか（コスト最適化との トレードオフ）

2. **バックアップ設定**
   - RDS: 自動バックアップが有効で保持期間が十分か（最低 7 日推奨）
   - DynamoDB: PITR（Point-In-Time Recovery）が有効か
   - S3: バージョニングが有効か
   - EBS: スナップショットのスケジュールが設定されているか

3. **フェイルオーバー**
   - RDS: Multi-AZ Deployment が有効か（フェイルオーバー約 1〜2 分）
   - Route53: ヘルスチェックとフェイルオーバールーティングが設定されているか
   - ALB: 正常なターゲットへの自動ルーティングが機能するか

4. **RPO / RTO 達成可能性**
   - RPO（目標復旧時点）: バックアップ・レプリケーションの頻度と目標が一致しているか
   - RTO（目標復旧時間）: 手動・自動復旧手順のリードタイムは目標内か
   - ウォームスタンバイや Pilot Light の必要性

5. **オートスケーリング**
   - ASG (Auto Scaling Group): スケールアウト/インのポリシーが適切か
   - ECS Service: desired count / min / max の設定は適切か
   - Lambda の同時実行数の制限（throttle 時の挙動）

6. **ヘルスチェックと自動復旧**
   - ALB ターゲットグループのヘルスチェック設定（interval, threshold）
   - CloudWatch Alarm + Auto Recovery（EC2 システム障害への自動対応）
   - Lambda の Dead Letter Queue（DLQ）設定

## 出力形式（JSON のみ出力すること）

```json
{
    "agent": "reliability",
    "findings": [
        {
            "severity": "HIGH",
            "resource": "aws_db_instance.main",
            "issue": "RDS が Single AZ 構成で、AZ 障害時にサービス停止が発生する",
            "recommendation": "multi_az = true を設定し、マルチ AZ 配置を有効にしてください（RTO: 約1〜2分）"
        }
    ],
    "score": 60,
    "summary": "Single AZ 構成が複数箇所で見られ、AZ 障害時の可用性に懸念があります。バックアップ設定は適切ですが、フェイルオーバー経路の整備が必要です。"
}
```

findings が空の場合は空リスト [] を返してください。
score は 0（最悪）〜 100（完璧）で評価してください。
summary は必ず2文以内にしてください。
JSON 以外のテキスト（説明文等）は一切出力しないでください。"""


def build_user_message(review_content: str, input_type: str) -> str:
    if input_type == "terraform":
        return f"以下の Terraform コードを可用性・信頼性観点でレビューしてください:\n\n```hcl\n{review_content}\n```"
    else:
        return f"以下の AWS アーキテクチャ構成を可用性・信頼性観点でレビューしてください:\n\n{review_content}"


def invoke_bedrock(review_content: str, input_type: str) -> dict:
    user_message = build_user_message(review_content, input_type)

    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_message}],
    }

    logger.info(f"Bedrock 呼び出し開始: model={MODEL_ID}, input_type={input_type}")

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(request_body),
    )

    response_body = json.loads(response["body"].read())
    raw_text = response_body["content"][0]["text"]

    logger.info(f"Bedrock レスポンス受信: {len(raw_text)} 文字")

    if "```json" in raw_text:
        raw_text = raw_text.split("```json")[1].split("```")[0].strip()
    elif "```" in raw_text:
        raw_text = raw_text.split("```")[1].split("```")[0].strip()

    return json.loads(raw_text)


def save_review_result(session_id: str, agent_result: dict) -> None:
    """
    レビュー結果を DynamoDB に保存する

    UpdateExpression で reliability キーのみ更新し、
    他エージェントの結果を上書きしない。
    """
    table = dynamodb.Table(TABLE_NAME)

    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET rounds.round_1.#agent = :result",
        ExpressionAttributeNames={"#agent": "reliability"},
        ExpressionAttributeValues={
            ":result": {
                "findings": agent_result.get("findings", []),
                "score": agent_result.get("score", 0),
                "summary": agent_result.get("summary", ""),
            }
        },
    )
    logger.info(f"DynamoDB 書き込み完了: session_id={session_id}")


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント

    Step Functions の Parallel State から呼び出される。

    Args:
        event: {
            "session_id": str,
            "review_content": str,
            "input_type": str  # "terraform" | "architecture"
        }
    Returns:
        可用性・信頼性レビュー結果 dict
    """
    logger.info(f"reliability-reviewer 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    review_content = event.get("review_content", "")
    input_type = event.get("input_type", "terraform")

    if not review_content:
        logger.error("review_content が空です")
        return {
            "agent": "reliability",
            "findings": [],
            "score": 0,
            "summary": "レビュー対象コンテンツが空のため評価できません。",
            "error": "review_content is empty",
        }

    try:
        result = invoke_bedrock(review_content, input_type)

        if session_id:
            save_review_result(session_id, result)

        # Step Functions 256KB ペイロード上限対策: severity 降順で最大 10 件に絞る
        _sev = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
        result["findings"] = sorted(
            result.get("findings", []),
            key=lambda f: _sev.get(f.get("severity", "LOW"), 2),
        )[:10]

        logger.info(
            f"reliability-reviewer 完了: score={result.get('score')}, "
            f"findings={len(result.get('findings', []))}件"
        )
        return result

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"AWS API エラー: {error_code} - {str(e)}")
        raise

    except json.JSONDecodeError as e:
        logger.error(f"Bedrock レスポンスの JSON パース失敗: {str(e)}")
        raise
