"""
operations-reviewer エージェント

役割:
    AWS インフラ（Terraform コードまたはアーキテクチャ図の説明）を
    運用性観点からレビューする専門エージェント。

チェック観点:
    - タグ戦略（Environment / Project / Owner / CostCenter の付与）
    - 監視設計（CloudWatch アラーム・ダッシュボード・メトリクス）
    - ログ出力（CloudTrail・VPC Flow Logs・アクセスログの有効化）
    - デプロイ戦略（Blue/Green・カナリアリリース・ロールバック手順）
    - ドリフト検知（Terraform State との乖離防止）
    - インシデント対応（アラート通知先・エスカレーション経路）

出力形式（CLAUDE.md 定義の JSON 統一形式）:
    {
        "agent": "operations",
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
# 運用性観点でのレビュー観点・出力形式を定義
# =============================================================================
SYSTEM_PROMPT = """あなたは AWS インフラの運用・オブザーバビリティの専門家です。
Terraform コードまたはアーキテクチャ構成を受け取り、日常運用の効率性と可視性を評価してください。

## チェック観点（必ず全項目を確認すること）

1. **タグ戦略**
   - 全リソースに必須タグが付与されているか
     - Environment（環境区分: dev/stg/prd）
     - Project（プロジェクト識別子）
     - Owner（担当者・チーム）
     - CostCenter（コスト配賦先）
   - タグを利用したコスト配賦・アクセス制御が実現できているか

2. **監視設計**
   - CloudWatch アラームが重要メトリクスに設定されているか
     - Lambda: エラー率・実行時間・スロットリング
     - RDS: CPU使用率・接続数・レプリカラグ
     - SQS: メッセージ滞留数・処理失敗数（DLQ）
     - API Gateway: 4xx/5xx エラー率
   - CloudWatch ダッシュボードでシステム全体が可視化されているか

3. **ログ出力**
   - CloudTrail: API コールの記録が有効か（監査ログ）
   - VPC Flow Logs: ネットワークトラフィックの記録
   - ALB/S3 アクセスログ: リクエストの追跡
   - Lambda: 適切なログレベルと CloudWatch Logs へのストリーミング
   - ログの保持期間は適切か（コストとコンプライアンスのバランス）

4. **デプロイ戦略**
   - Lambda: エイリアスと加重ルーティングでカナリアデプロイ可能か
   - ECS/Fargate: ローリングアップデートのパラメータ設定
   - CodeDeploy 統合でのブルーグリーンデプロイ
   - ロールバック手順が明確か（Terraform state の巻き戻し方法）

5. **ドリフト検知**
   - Terraform による全リソース管理（手動変更の禁止）
   - Config Rules でコンプライアンス違反を継続チェック
   - AWS Config と Terraform State の差分検出方法

6. **インシデント対応**
   - CloudWatch Alarm の通知先が設定されているか（SNS → Chatwork/PagerDuty）
   - ランブック（Runbook）の参照・実行が容易か
   - CloudWatch Logs Insights でのログ検索が迅速にできるか

## 出力形式（JSON のみ出力すること）

```json
{
    "agent": "operations",
    "findings": [
        {
            "severity": "MEDIUM",
            "resource": "aws_lambda_function.processor",
            "issue": "Lambda 関数にエラー率・タイムアウトの CloudWatch Alarm が設定されていない",
            "recommendation": "エラー率 > 5% または実行時間 > 55秒 でアラームを設定し、SNS 経由で通知してください"
        }
    ],
    "score": 65,
    "summary": "タグ戦略とログ設定は整備されていますが、監視アラームとインシデント通知の設定が不足しています。デプロイ戦略の文書化も推奨します。"
}
```

findings が空の場合は空リスト [] を返してください。
score は 0（最悪）〜 100（完璧）で評価してください。
summary は必ず2文以内にしてください。
JSON 以外のテキスト（説明文等）は一切出力しないでください。"""


def build_user_message(review_content: str, input_type: str) -> str:
    if input_type == "terraform":
        return f"以下の Terraform コードを運用性観点でレビューしてください:\n\n```hcl\n{review_content}\n```"
    else:
        return f"以下の AWS アーキテクチャ構成を運用性観点でレビューしてください:\n\n{review_content}"


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

    UpdateExpression で operations キーのみ更新し、
    他エージェントの結果を上書きしない。
    """
    table = dynamodb.Table(TABLE_NAME)

    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET rounds.round_1.#agent = :result",
        ExpressionAttributeNames={"#agent": "operations"},
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
        運用性レビュー結果 dict
    """
    logger.info(f"operations-reviewer 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    review_content = event.get("review_content", "")
    input_type = event.get("input_type", "terraform")

    if not review_content:
        logger.error("review_content が空です")
        return {
            "agent": "operations",
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
            f"operations-reviewer 完了: score={result.get('score')}, "
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
