"""
cost-reviewer エージェント

役割:
    AWS インフラ（Terraform コードまたはアーキテクチャ図の説明）を
    コスト最適化観点からレビューする専門エージェント。

チェック観点:
    - リソース過剰スペック（Lambda メモリ・RDS インスタンスタイプ等）
    - NAT Gateway 数（$0.062/時間 × 台数 = 高コスト要因）
    - Savings Plans / Reserved Instances の適用可否
    - 不要リソース・孤立リソース（未使用 EIP・スナップショット）
    - DynamoDB プロビジョンドキャパシティの過剰設定
    - S3 ストレージクラスの最適化（Standard → IA / Glacier）
    - データ転送コスト（リージョン間・インターネット向け）

出力形式（CLAUDE.md 定義の JSON 統一形式）:
    {
        "agent": "cost",
        "findings": [
            {
                "severity": "HIGH|MEDIUM|LOW",
                "resource": "リソース名",
                "issue": "問題の説明",
                "recommendation": "具体的な修正案"
            }
        ],
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
# コスト観点でのレビュー観点・出力形式を定義
# =============================================================================
SYSTEM_PROMPT = """あなたは AWS インフラのコスト最適化スペシャリストです。
Terraform コードまたはアーキテクチャ構成を受け取り、コスト削減の機会を特定してください。

## チェック観点（必ず全項目を確認すること）

1. **リソーススペック最適化**
   - Lambda: メモリ設定は実行時間とのバランスが取れているか（過大スペックはコスト増）
   - RDS/ElastiCache: インスタンスタイプは利用量に見合っているか
   - EC2: 未使用スペックがないか（CPU/メモリ使用率の推定）

2. **NAT Gateway**
   - NAT Gateway は 1 台で $32〜/月かかる高コストリソース
   - 複数 AZ に配置している場合、本当に必要かを評価
   - VPC エンドポイント（無料の Gateway 型）で代替できないか

3. **Savings Plans / Reserved Instances**
   - 常時稼働するリソース（RDS, ElastiCache, EC2）に RI/SP を適用できるか
   - Lambda の Compute Savings Plans 適用可否

4. **不要リソース**
   - 未使用 EIP（割り当てのみで未アタッチ: $0.005/時間）
   - 孤立したスナップショット・AMI
   - 空の S3 バケット（ライフサイクルポリシー未設定）

5. **DynamoDB 最適化**
   - プロビジョンドキャパシティが過剰に設定されていないか
   - PAY_PER_REQUEST（オンデマンド）と Provisioned の選択は適切か
   - DAX キャッシュの必要性（アクセスパターンの確認）

6. **S3 ストレージクラス**
   - アクセス頻度に基づいたストレージクラスの選択
   - S3 Intelligent-Tiering の適用可否
   - ライフサイクルポリシーで古いバージョン・不要データを削除しているか

7. **データ転送コスト**
   - リージョン間・アベイラビリティゾーン間のデータ転送が最小化されているか
   - CDN（CloudFront）の活用で S3/ALB からの転送コストを削減できるか

## 出力形式（JSON のみ出力すること）

```json
{
    "agent": "cost",
    "findings": [
        {
            "severity": "HIGH",
            "resource": "aws_nat_gateway.main",
            "issue": "NAT Gateway が 2 台設定されており月額約 $64 のコストが発生",
            "recommendation": "開発環境では NAT Gateway を 1 台に削減し、VPC エンドポイント（Gateway 型）を活用してください"
        }
    ],
    "score": 70,
    "summary": "NAT Gateway の多重配置とプロビジョンドキャパシティの過剰設定によりコストが最適化されていません。Savings Plans の適用と S3 ライフサイクルポリシーの設定を推奨します。"
}
```

findings が空の場合は空リスト [] を返してください。
score は 0（最悪）〜 100（完璧）で評価してください。
summary は必ず2文以内にしてください。
JSON 以外のテキスト（説明文等）は一切出力しないでください。"""


def build_user_message(review_content: str, input_type: str) -> str:
    if input_type == "terraform":
        return f"以下の Terraform コードをコスト最適化観点でレビューしてください:\n\n```hcl\n{review_content}\n```"
    else:
        return f"以下の AWS アーキテクチャ構成をコスト最適化観点でレビューしてください:\n\n{review_content}"


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

    # コードブロックで包まれている場合の対処
    if "```json" in raw_text:
        raw_text = raw_text.split("```json")[1].split("```")[0].strip()
    elif "```" in raw_text:
        raw_text = raw_text.split("```")[1].split("```")[0].strip()

    return json.loads(raw_text)


def save_review_result(session_id: str, agent_result: dict) -> None:
    """
    レビュー結果を DynamoDB に保存する

    UpdateExpression で cost キーのみ更新し、
    他エージェント（security, reliability, operations）の結果を上書きしない。
    """
    table = dynamodb.Table(TABLE_NAME)

    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET rounds.round_1.#agent = :result",
        ExpressionAttributeNames={"#agent": "cost"},
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
        コストレビュー結果 dict
    """
    logger.info(f"cost-reviewer 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    review_content = event.get("review_content", "")
    input_type = event.get("input_type", "terraform")

    if not review_content:
        logger.error("review_content が空です")
        return {
            "agent": "cost",
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
            f"cost-reviewer 完了: score={result.get('score')}, "
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
