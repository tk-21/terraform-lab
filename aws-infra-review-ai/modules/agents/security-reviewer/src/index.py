"""
security-reviewer エージェント

役割:
    AWS インフラ（Terraform コードまたはアーキテクチャ図の説明）を
    セキュリティ観点からレビューする専門エージェント。

チェック観点:
    - IAM 最小権限原則の遵守（wildcard action/resource の検出）
    - 保存時暗号化（S3, EBS, RDS, DynamoDB の encryption 設定）
    - 転送時暗号化（TLS 強制、HTTPS リスナー）
    - VPC エンドポイント設定（プライベート通信の実現）
    - パブリック露出リスク（S3 パブリックアクセス、SG 0.0.0.0/0）
    - Secrets のハードコード検出（パスワード・APIキーの直書き）
    - セキュリティグループの過剰開放（0.0.0.0/0 の inbound）

出力形式（CLAUDE.md 定義の JSON 統一形式）:
    {
        "agent": "security",
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

# ロガー設定（CloudWatch Logs に出力）
logger = logging.getLogger()
logger.setLevel(logging.INFO)

# AWS クライアント初期化（Lambda コンテナ再利用時にキャッシュされる）
bedrock = boto3.client("bedrock-runtime", region_name="ap-northeast-1")
dynamodb = boto3.resource("dynamodb", region_name="ap-northeast-1")

# 環境変数
TABLE_NAME = os.environ["DYNAMODB_TABLE_NAME"]
MODEL_ID = os.environ["BEDROCK_MODEL_ID"]
AGENT_NAME = os.environ["AGENT_NAME"]

# =============================================================================
# システムプロンプト
# エージェントの役割・チェック観点・出力形式を定義
# =============================================================================
SYSTEM_PROMPT = """あなたは AWS インフラのセキュリティ審査官です。
Terraform コードまたはアーキテクチャ構成を受け取り、セキュリティリスクを特定してください。

## チェック観点（必ず全項目を確認すること）

1. **IAM 最小権限原則**
   - Action や Resource に wildcard (*) が使用されていないか
   - 不要な権限（Admin ポリシーのアタッチ）がないか
   - クロスアカウントアクセスに適切な条件が付いているか

2. **暗号化設定**
   - S3: サーバーサイド暗号化（SSE）が有効か
   - EBS/RDS/DynamoDB: 保存時暗号化が有効か
   - 転送時: TLS が強制されているか（HTTPS リスナー、enforce_ssl）

3. **VPC エンドポイント**
   - Bedrock, S3, DynamoDB 等の AWS サービスへの通信が
     インターネットを経由していないか
   - プライベートサブネットから適切にルーティングされているか

4. **パブリック露出リスク**
   - S3 バケットのパブリックアクセスブロックが有効か
   - RDS, ElastiCache 等のデータストアが publicly accessible でないか
   - ALB/NLB が適切なスコープで公開されているか

5. **セキュリティグループ**
   - inbound ルールに 0.0.0.0/0 が広範囲で許可されていないか
   - 不要なポートが開放されていないか

6. **Secrets 管理**
   - パスワード・API キー・トークンが Terraform コードに直書きされていないか
   - Secrets Manager または Parameter Store が適切に使用されているか

## 出力形式（JSON のみ出力すること）

```json
{
    "agent": "security",
    "findings": [
        {
            "severity": "HIGH",
            "resource": "aws_iam_role_policy.example",
            "issue": "Action に wildcard (*) が使用されており最小権限に違反",
            "recommendation": "必要な Action を明示的にリストアップしてください（例: s3:GetObject, s3:PutObject）"
        }
    ],
    "score": 75,
    "summary": "暗号化設定は適切ですが、IAM ポリシーに過剰な権限が見られます。セキュリティグループのインバウンドルールの絞り込みも推奨します。"
}
```

findings が空の場合は空リスト [] を返してください。
score は 0（最悪）〜 100（完璧）で評価してください。
summary は必ず2文以内にしてください。
JSON 以外のテキスト（説明文等）は一切出力しないでください。"""


def build_user_message(review_content: str, input_type: str) -> str:
    """
    Bedrock に送るユーザーメッセージを組み立てる

    Args:
        review_content: レビュー対象のコードまたは説明文
        input_type: "terraform" または "architecture"

    Returns:
        フォーマット済みのプロンプト文字列
    """
    if input_type == "terraform":
        return f"以下の Terraform コードをセキュリティ観点でレビューしてください:\n\n```hcl\n{review_content}\n```"
    else:
        return f"以下の AWS アーキテクチャ構成をセキュリティ観点でレビューしてください:\n\n{review_content}"


def invoke_bedrock(review_content: str, input_type: str) -> dict:
    """
    Bedrock Claude 3.5 Sonnet を呼び出してセキュリティレビューを実施

    Args:
        review_content: レビュー対象コンテンツ
        input_type: 入力種別

    Returns:
        パース済みのレビュー結果 dict

    Raises:
        ClientError: Bedrock API 呼び出し失敗時
        json.JSONDecodeError: モデル出力が不正な JSON の場合
    """
    user_message = build_user_message(review_content, input_type)

    # Bedrock Messages API 形式でリクエスト
    request_body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 4096,
        "system": SYSTEM_PROMPT,
        "messages": [
            {
                "role": "user",
                "content": user_message,
            }
        ],
    }

    logger.info(f"Bedrock 呼び出し開始: model={MODEL_ID}, input_type={input_type}")

    response = bedrock.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(request_body),
    )

    # レスポンスボディを読み取りパース
    response_body = json.loads(response["body"].read())
    raw_text = response_body["content"][0]["text"]

    logger.info(f"Bedrock レスポンス受信: {len(raw_text)} 文字")

    # モデルが JSON のみを返す前提だが、コードブロックで包まれる場合を考慮
    if "```json" in raw_text:
        raw_text = raw_text.split("```json")[1].split("```")[0].strip()
    elif "```" in raw_text:
        raw_text = raw_text.split("```")[1].split("```")[0].strip()

    return json.loads(raw_text)


def save_review_result(session_id: str, agent_result: dict) -> None:
    """
    レビュー結果を DynamoDB に保存する

    DynamoDB スキーマ（CLAUDE.md 定義）:
        review_sessions テーブル
        └── session_id (PK)
            └── rounds.round_1.security: { findings, score, summary }

    Args:
        session_id: レビューセッション ID
        agent_result: エージェントのレビュー結果 dict
    """
    table = dynamodb.Table(TABLE_NAME)

    # UpdateItem で security レビュー結果のみ更新（他エージェントの結果を上書きしない）
    table.update_item(
        Key={"session_id": session_id},
        UpdateExpression="SET rounds.round_1.#agent = :result",
        ExpressionAttributeNames={"#agent": "security"},
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
            "session_id": str,          # レビューセッション ID
            "review_content": str,      # レビュー対象コンテンツ
            "input_type": str           # "terraform" | "architecture"
        }
        context: Lambda コンテキスト

    Returns:
        エージェントのレビュー結果 dict（Step Functions の次のステートに渡される）
    """
    logger.info(f"security-reviewer 開始: session_id={event.get('session_id')}")

    # 入力バリデーション
    session_id = event.get("session_id", "")
    review_content = event.get("review_content", "")
    input_type = event.get("input_type", "terraform")

    if not review_content:
        logger.error("review_content が空です")
        return {
            "agent": "security",
            "findings": [],
            "score": 0,
            "summary": "レビュー対象コンテンツが空のため評価できません。",
            "error": "review_content is empty",
        }

    try:
        # Bedrock でセキュリティレビューを実行
        result = invoke_bedrock(review_content, input_type)

        # DynamoDB にレビュー結果を保存（セッション ID がある場合のみ）
        if session_id:
            save_review_result(session_id, result)

        # Step Functions 256KB ペイロード上限対策: severity 降順で最大 10 件に絞る
        _sev = {"HIGH": 0, "MEDIUM": 1, "LOW": 2}
        result["findings"] = sorted(
            result.get("findings", []),
            key=lambda f: _sev.get(f.get("severity", "LOW"), 2),
        )[:10]

        logger.info(
            f"security-reviewer 完了: score={result.get('score')}, "
            f"findings={len(result.get('findings', []))}件"
        )
        return result

    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error(f"AWS API エラー: {error_code} - {str(e)}")
        # Step Functions にエラーを伝播させる（リトライ・エラーハンドリングは SFN 側で実施）
        raise

    except json.JSONDecodeError as e:
        logger.error(f"Bedrock レスポンスの JSON パース失敗: {str(e)}")
        raise
