"""
supervisor エージェント

役割:
    security / cost / reliability / operations の 4 エージェントが出力した
    レビュー結果を受け取り、以下を行う:

    1. エージェント間のトレードオフを明示
       例: security が VPC エンドポイントを推奨 ⟷ cost が追加費用を懸念
    2. 全指摘事項を横断してリスク・影響度別に優先順位を付ける
    3. 各エージェントのスコアを集約し総合スコアを算出
    4. 経営層向けエグゼクティブサマリーを生成（3 文以内）

入力（Step Functions Parallel State の出力から渡される）:
    {
        "session_id":     "uuid4",
        "input_type":     "terraform" | "architecture",
        "review_content": "レビュー対象のファイル内容",
        "agent_results":  [
            { "agent": "security",     "findings": [...], "score": 80, "summary": "..." },
            { "agent": "cost",         "findings": [...], "score": 70, "summary": "..." },
            { "agent": "reliability",  "findings": [...], "score": 75, "summary": "..." },
            { "agent": "operations",   "findings": [...], "score": 65, "summary": "..." }
        ]
    }

出力形式（JSON 統一形式）:
    {
        "agent": "supervisor",
        "tradeoffs": [
            {
                "description": "VPC エンドポイント追加: セキュリティ向上 vs コスト増加",
                "agents":      ["security", "cost"],
                "recommendation": "セキュリティリスクを考慮し追加を推奨するが不要なものは削減する"
            }
        ],
        "priority_actions": [
            {
                "rank":         1,
                "action":       "IAM ポリシーのワイルドカード除去",
                "source_agent": "security",
                "severity":     "HIGH"
            }
        ],
        "overall_score": {
            "security":     80,
            "cost":         70,
            "reliability":  75,
            "operations":   65,
            "total":        73
        },
        "executive_summary": "..."
    }

DynamoDB 書き込み先:
    rounds.round_2 に上記結果を保存する
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
# 複数エージェントの結果を統合するメタ審査官として振る舞う
# =============================================================================
SYSTEM_PROMPT = """あなたは AWS インフラレビューの統合審査官（スーパーバイザー）です。
security / cost / reliability / operations の 4 つの専門エージェントが出力したレビュー結果を受け取り、
それらを統合・整理した最終レビューを作成してください。

## あなたの役割

1. **トレードオフの明示**
   - あるエージェントの推奨が別のエージェントの観点と矛盾・競合する箇所を特定する
     - 例: security「VPC エンドポイントを追加すべき」 ↔ cost「エンドポイント料金が月 $XX 発生する」
     - 例: reliability「Multi-AZ 構成が必要」 ↔ cost「インスタンス費用が 2 倍になる」
   - どちらの観点を優先すべきか、文脈に応じた推奨を出す

2. **優先対応アクションの絞り込み**
   - 全エージェントの findings を横断して評価し、対応優先度 TOP 10 を特定する
   - 優先度の判断基準: セキュリティリスク > サービス影響 > コスト > 運用効率
   - 修正コストが低いのに効果が高いもの（Quick Win）は優先度を上げる

3. **総合スコアの算出**
   - 各エージェントのスコアをそのまま使用する（再評価は不要）
   - total = (security × 0.35 + cost × 0.20 + reliability × 0.30 + operations × 0.15) の加重平均

4. **エグゼクティブサマリーの生成**
   - 最も重要な課題と全体評価を 3 文以内でまとめる
   - 技術的な詳細よりもビジネスインパクトを意識して記述する

## 出力形式（JSON のみ出力すること）

```json
{
    "agent": "supervisor",
    "tradeoffs": [
        {
            "description": "VPC エンドポイント追加によるセキュリティ強化とコスト増加のトレードオフ",
            "agents": ["security", "cost"],
            "recommendation": "本番環境では S3/DynamoDB の Gateway エンドポイント（無料）から着手し、Interface エンドポイントは必要なものに限定する"
        }
    ],
    "priority_actions": [
        {
            "rank": 1,
            "action": "IAM ポリシーのワイルドカード Action を特定のアクションに絞り込む",
            "source_agent": "security",
            "severity": "HIGH"
        }
    ],
    "overall_score": {
        "security": 72,
        "cost": 88,
        "reliability": 75,
        "operations": 65,
        "total": 75
    },
    "executive_summary": "セキュリティと信頼性に中程度のリスクが存在し、特に IAM 権限の過剰付与と Single AZ 構成が早急な対応を要します。コスト効率は良好ですが、監視・アラート設定の整備が運用安定化の鍵となります。"
}
```

tradeoffs が存在しない場合は空リスト [] を返してください。
priority_actions は最大 10 件に絞ってください。
total スコアは小数点以下を切り捨てた整数で返してください。
JSON 以外のテキスト（説明文等）は一切出力しないでください。"""


def build_user_message(
    review_content: str, input_type: str, agent_results: list
) -> str:
    """
    スーパーバイザーへのプロンプトを構築する

    各エージェントの結果を整形してプロンプトに埋め込む。
    review_content が大きい場合に備えて先頭 3000 文字に制限する。

    Args:
        review_content: レビュー対象ファイルの内容
        input_type:     "terraform" | "architecture"
        agent_results:  4 エージェントの結果リスト

    Returns:
        ユーザーメッセージ文字列
    """
    content_label = "Terraform コード" if input_type == "terraform" else "アーキテクチャ構成"

    # レビュー対象（大きいファイルは先頭のみ）
    truncated = review_content[:3000]
    if len(review_content) > 3000:
        truncated += "\n... (以下省略)"

    # 各エージェントの結果を整形
    agents_section = ""
    for result in agent_results:
        agent_name = result.get("agent", "unknown")
        score = result.get("score", 0)
        summary = result.get("summary", "")
        findings = result.get("findings", [])

        agents_section += f"\n### {agent_name} エージェント（スコア: {score}/100）\n"
        agents_section += f"所見: {summary}\n"

        if findings:
            agents_section += "指摘事項（上位 5 件）:\n"
            for f in findings[:5]:
                severity = f.get("severity", "?")
                resource = f.get("resource", "")
                issue = f.get("issue", "")
                agents_section += f"  [{severity}] {resource}: {issue}\n"

    return f"""以下の {content_label} に対して、4 つの専門エージェントがレビューを行いました。
各エージェントの結果を統合し、トレードオフと優先対応アクションを明示した総合レビューを作成してください。

## レビュー対象（{content_label}）

```
{truncated}
```

## 各エージェントのレビュー結果
{agents_section}
"""


def invoke_bedrock(review_content: str, input_type: str, agent_results: list) -> dict:
    """
    Bedrock (Claude) を呼び出して統合レビューを生成する

    Args:
        review_content: レビュー対象コンテンツ
        input_type:     入力種別
        agent_results:  4 エージェントの結果リスト

    Returns:
        スーパーバイザーのレビュー結果 dict
    """
    user_message = build_user_message(review_content, input_type, agent_results)

    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "system": SYSTEM_PROMPT,
        "messages": [{"role": "user", "content": user_message}],
    }

    logger.info(f"Bedrock 呼び出し開始: model={MODEL_ID}, agents={len(agent_results)}件")

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(request_body),
    )

    response_body = json.loads(response["body"].read())
    raw_text = response_body["content"][0]["text"]

    logger.info(f"Bedrock レスポンス受信: {len(raw_text)} 文字")

    # Bedrock がコードブロックで JSON を返す場合に対応
    if "```json" in raw_text:
        raw_text = raw_text.split("```json")[1].split("```")[0].strip()
    elif "```" in raw_text:
        raw_text = raw_text.split("```")[1].split("```")[0].strip()

    return json.loads(raw_text)


def save_review_result(session_id: str, result: dict) -> None:
    """
    統合レビュー結果を DynamoDB の rounds.round_2 に保存する

    round_1 は各エージェントが個別に書き込んでいるため、
    supervisor は round_2 のみ書き込む（round_1 を上書きしない）。

    Args:
        session_id: セッション ID
        result:     supervisor のレビュー結果 dict
    """
    table = dynamodb.Table(TABLE_NAME)

    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET rounds.round_2 = :round2",
        ExpressionAttributeValues={
            ":round2": {
                "tradeoffs": result.get("tradeoffs", []),
                "priority_actions": result.get("priority_actions", []),
                "overall_score": result.get("overall_score", {}),
                "executive_summary": result.get("executive_summary", ""),
            }
        },
    )
    logger.info(f"DynamoDB 書き込み完了（rounds.round_2）: session_id={session_id}")


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント

    Step Functions の SupervisorReview ステートから呼び出される。

    Args:
        event: {
            "session_id":     str,
            "input_type":     str,
            "review_content": str,
            "agent_results":  list  # Parallel State の出力（4 要素の配列）
        }

    Returns:
        supervisor のレビュー結果 dict
    """
    logger.info(f"supervisor 開始: session_id={event.get('session_id')}")

    session_id = event.get("session_id", "")
    input_type = event.get("input_type", "terraform")
    review_content = event.get("review_content", "")
    agent_results = event.get("agent_results", [])

    if not review_content:
        logger.error("review_content が空です")
        return {
            "agent": "supervisor",
            "tradeoffs": [],
            "priority_actions": [],
            "overall_score": {
                "security": 0,
                "cost": 0,
                "reliability": 0,
                "operations": 0,
                "total": 0,
            },
            "executive_summary": "レビュー対象コンテンツが空のため評価できません。",
            "error": "review_content is empty",
        }

    if not agent_results:
        logger.error("agent_results が空です")
        return {
            "agent": "supervisor",
            "tradeoffs": [],
            "priority_actions": [],
            "overall_score": {
                "security": 0,
                "cost": 0,
                "reliability": 0,
                "operations": 0,
                "total": 0,
            },
            "executive_summary": "エージェント結果が取得できなかったため統合できません。",
            "error": "agent_results is empty",
        }

    logger.info(
        f"受信したエージェント結果: "
        f"{[r.get('agent', '?') for r in agent_results]}"
    )

    try:
        result = invoke_bedrock(review_content, input_type, agent_results)

        if session_id:
            save_review_result(session_id, result)

        logger.info(
            f"supervisor 完了: total_score={result.get('overall_score', {}).get('total')}, "
            f"tradeoffs={len(result.get('tradeoffs', []))}件, "
            f"priority_actions={len(result.get('priority_actions', []))}件"
        )
        return result

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"AWS API エラー: {error_code} - {str(e)}")
        raise

    except json.JSONDecodeError as e:
        logger.error(f"Bedrock レスポンスの JSON パース失敗: {str(e)}")
        raise
