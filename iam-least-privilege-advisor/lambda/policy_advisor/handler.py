"""
policy-advisor Lambda ハンドラー

処理フロー:
  1. イベントから S3 キーを取得（なければ当日の最新ファイルを S3 から取得）
  2. S3 から findings.json を読み込み
  3. findings をロール ARN でグループ化
  4. 各ロールに対して:
       a. IamFetcher でマネージドポリシー取得
       b. BedrockClient で最小権限ポリシー生成
       c. validate_ai_policy() で AI 出力検証（失敗時はスキップ・警告ログ）
       d. TerraformFormatter で HCL 変換
       e. GithubPrCreator で PR 作成
       f. ChatworkNotifier で通知
  5. 処理件数・PR 作成数・スキップ数をログ出力して返す
"""

import json
import logging
import os
from collections import defaultdict
from datetime import datetime, timezone, timedelta

import boto3

from bedrock_client import BedrockClient
from chatwork_notifier import ChatworkNotifier
from github_pr_creator import GithubPrCreator
from iam_fetcher import IamFetcher
from terraform_formatter import TerraformFormatter

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

JST = timezone(timedelta(hours=9))

S3_BUCKET_NAME = os.environ["S3_BUCKET_NAME"]
GITHUB_TOKEN_SECRET_ARN = os.environ["GITHUB_TOKEN_SECRET_ARN"]
CHATWORK_SECRET_ARN = os.environ["CHATWORK_SECRET_ARN"]
CHATWORK_ROOM_ID = os.environ["CHATWORK_ROOM_ID"]
GITHUB_OWNER = os.environ["GITHUB_OWNER"]
GITHUB_REPO = os.environ["GITHUB_REPO"]
BEDROCK_MODEL_ID = os.environ["BEDROCK_MODEL_ID"]


def lambda_handler(event: dict, context) -> dict:
    """
    Lambda エントリーポイント。

    analyzer-trigger から非同期で起動される。
    findings.json を読み込み、ロールごとに最小権限 PR を作成する。

    Args:
        event: {"s3_key": "<key>"} を含む辞書（キーがなければ当日最新を自動検索）
        context: Lambda コンテキストオブジェクト

    Returns:
        {"statusCode": 200, "processed": int, "pr_created": int, "skipped": int}
    """
    logger.info("policy-advisor 開始: event=%s", json.dumps(event))

    s3_client = boto3.client("s3")
    s3_key = _resolve_s3_key(event, s3_client)
    logger.info("対象 S3 キー: %s", s3_key)

    scan_result = _load_findings_from_s3(s3_client, s3_key)
    scan_date = scan_result.get("scan_date", "不明")
    findings = scan_result.get("findings", [])
    logger.info("Findings 合計: %d 件", len(findings))

    grouped = _group_findings_by_role(findings)
    logger.info("対象ロール数: %d", len(grouped))

    iam_fetcher = IamFetcher()
    bedrock = BedrockClient(model_id=BEDROCK_MODEL_ID)
    pr_creator = GithubPrCreator(
        token_secret_arn=GITHUB_TOKEN_SECRET_ARN,
        owner=GITHUB_OWNER,
        repo=GITHUB_REPO,
    )
    notifier = ChatworkNotifier(
        secret_arn=CHATWORK_SECRET_ARN,
        room_id=CHATWORK_ROOM_ID,
    )

    processed = pr_created = skipped = 0

    for role_arn, role_findings in grouped.items():
        processed += 1
        role_name = role_arn.split("/")[-1]
        logger.info("処理中: %s", role_arn)

        result = _process_role(
            role_arn=role_arn,
            role_name=role_name,
            role_findings=role_findings,
            scan_date=scan_date,
            iam_fetcher=iam_fetcher,
            bedrock=bedrock,
            pr_creator=pr_creator,
            notifier=notifier,
        )

        if result:
            pr_created += 1
        else:
            skipped += 1

    logger.info(
        "policy-advisor 完了: processed=%d pr_created=%d skipped=%d",
        processed,
        pr_created,
        skipped,
    )

    return {
        "statusCode": 200,
        "processed": processed,
        "pr_created": pr_created,
        "skipped": skipped,
    }


def validate_ai_policy(
    original_policy: dict,
    revised_policy: dict,
    unused_actions: list[str],
) -> tuple[bool, str]:
    """
    AI が生成したポリシーを検証する。

    # AI出力検証: 以下の5項目をすべてパスした場合のみ True を返す
    # 1. revised_policy に Version と Statement が存在するか
    # 2. unused_actions 以外のアクションが削除されていないか
    # 3. Resource 指定が元のポリシーから変更されていないか
    # 4. Condition が元のポリシーから変更・削除されていないか
    # 5. Effect: Deny の Statement が変更されていないか

    Args:
        original_policy: 元の IAM ポリシードキュメント
        revised_policy: AI が生成した修正後のポリシードキュメント
        unused_actions: 削除が許可されている未使用アクションの一覧

    Returns:
        (is_valid: bool, error_message: str)
        is_valid=True の場合、error_message は空文字列
    """
    # AI出力検証: 1. 有効な IAM ポリシー構造か（Version, Statement が存在するか）
    if "Version" not in revised_policy:
        return False, "revised_policy に Version が存在しません"
    if "Statement" not in revised_policy or not isinstance(
        revised_policy["Statement"], list
    ):
        return False, "revised_policy に Statement リストが存在しません"

    original_stmts = {
        _stmt_key(s): s for s in original_policy.get("Statement", [])
    }
    revised_stmts = {
        _stmt_key(s): s for s in revised_policy.get("Statement", [])
    }

    unused_set = {a.lower() for a in unused_actions}

    for key, orig_stmt in original_stmts.items():
        # AI出力検証: 5. Effect: Deny の Statement が変更されていないか
        if orig_stmt.get("Effect") == "Deny":
            rev_stmt = revised_stmts.get(key)
            if rev_stmt is None:
                return False, f"Deny Statement が削除されています: Sid={key}"
            if json.dumps(orig_stmt, sort_keys=True) != json.dumps(
                rev_stmt, sort_keys=True
            ):
                return False, f"Deny Statement が変更されています: Sid={key}"
            continue

        # Allow Statement の検証
        rev_stmt = revised_stmts.get(key)
        if rev_stmt is None:
            # Statement ごと削除は、全アクションが unused_actions に含まれる場合のみ許可
            orig_actions = _normalize_actions(orig_stmt.get("Action", []))
            non_unused = orig_actions - unused_set
            if non_unused:
                return (
                    False,
                    f"未使用アクション以外を含む Statement が削除されています: "
                    f"Sid={key}, 残存すべきアクション={non_unused}",
                )
            continue

        # AI出力検証: 2. unused_actions 以外のアクションが削除されていないか
        orig_actions = _normalize_actions(orig_stmt.get("Action", []))
        rev_actions = _normalize_actions(rev_stmt.get("Action", []))
        illegally_removed = (orig_actions - rev_actions) - unused_set
        if illegally_removed:
            return (
                False,
                f"unused_actions 以外のアクションが削除されています: "
                f"Sid={key}, 不正削除={illegally_removed}",
            )

        # AI出力検証: 3. Resource 指定が元のポリシーから変更されていないか
        if json.dumps(orig_stmt.get("Resource"), sort_keys=True) != json.dumps(
            rev_stmt.get("Resource"), sort_keys=True
        ):
            return False, f"Resource 指定が変更されています: Sid={key}"

        # AI出力検証: 4. Condition が元のポリシーから変更・削除されていないか
        orig_condition = orig_stmt.get("Condition")
        rev_condition = rev_stmt.get("Condition")
        if json.dumps(orig_condition, sort_keys=True) != json.dumps(
            rev_condition, sort_keys=True
        ):
            return False, f"Condition が変更または削除されています: Sid={key}"

    return True, ""


# ------------------------------------------------------------------
# モジュールレベルのヘルパー関数
# ------------------------------------------------------------------


def _resolve_s3_key(event: dict, s3_client) -> str:
    """
    イベントから S3 キーを取得する。イベントにキーがなければ当日最新ファイルを返す。

    IAM アクション: s3:ListObjectsV2（最新ファイル検索時のみ）

    Args:
        event: Lambda イベント辞書
        s3_client: boto3 s3 クライアント

    Returns:
        S3 オブジェクトキー文字列

    Raises:
        RuntimeError: 当日の Findings ファイルが存在しない場合
    """
    if "s3_key" in event:
        return event["s3_key"]

    today = datetime.now(JST)
    prefix = f"analyzer-results/{today.strftime('%Y/%m/%d')}/"

    # IAM アクション: s3:ListObjectsV2
    resp = s3_client.list_objects_v2(
        Bucket=S3_BUCKET_NAME,
        Prefix=prefix,
    )
    objects = resp.get("Contents", [])
    if not objects:
        raise RuntimeError(
            f"当日の Findings ファイルが見つかりません: prefix={prefix}"
        )

    latest = max(objects, key=lambda o: o["LastModified"])
    return latest["Key"]


def _load_findings_from_s3(s3_client, s3_key: str) -> dict:
    """
    S3 から findings.json を読み込んで辞書として返す。

    IAM アクション: s3:GetObject

    Args:
        s3_client: boto3 s3 クライアント
        s3_key: 読み込む S3 オブジェクトキー

    Returns:
        findings.json の内容を辞書化したもの
    """
    # IAM アクション: s3:GetObject
    resp = s3_client.get_object(Bucket=S3_BUCKET_NAME, Key=s3_key)
    return json.loads(resp["Body"].read().decode("utf-8"))


def _group_findings_by_role(findings: list[dict]) -> dict[str, list[dict]]:
    """
    Findings をロール ARN でグループ化して返す。

    Args:
        findings: analyzer-trigger が保存した findings のリスト

    Returns:
        {role_arn: [finding, ...]} の辞書
    """
    grouped: dict[str, list[dict]] = defaultdict(list)
    for finding in findings:
        grouped[finding["resource_arn"]].append(finding)
    return dict(grouped)


def _process_role(
    role_arn: str,
    role_name: str,
    role_findings: list[dict],
    scan_date: str,
    iam_fetcher: IamFetcher,
    bedrock: BedrockClient,
    pr_creator: GithubPrCreator,
    notifier: ChatworkNotifier,
) -> bool:
    """
    単一ロールに対して最小権限化 PR 作成の全処理を実行する。

    IAM ポリシー取得失敗・AI 検証失敗・Bedrock 失敗の場合はスキップしてログ出力する。
    GitHub API 失敗は raise して Lambda エラーとして記録する。

    Args:
        role_arn: 対象 IAM ロールの ARN
        role_name: 対象ロール名
        role_findings: そのロールの Findings リスト
        scan_date: Access Analyzer スキャン日時文字列
        iam_fetcher: IamFetcher インスタンス
        bedrock: BedrockClient インスタンス
        pr_creator: GithubPrCreator インスタンス
        notifier: ChatworkNotifier インスタンス

    Returns:
        PR を作成した場合 True、スキップした場合 False
    """
    # 全 Finding の未使用アクションをマージ（重複除去・順序保持）
    seen: dict[str, None] = {}
    for finding in role_findings:
        for action in finding.get("unused_actions", []):
            seen[action] = None
    all_unused_actions = list(seen.keys())

    last_accessed = next(
        (f["last_accessed"] for f in role_findings if f.get("last_accessed")),
        None,
    )

    # a. マネージドポリシー取得
    policies = iam_fetcher.get_managed_policies(role_arn)
    if not policies:
        logger.warning("マネージドポリシーなし（スキップ）: %s", role_arn)
        return False

    pr_created_any = False

    for policy in policies:
        policy_name = policy["policy_name"]
        policy_arn = policy["policy_arn"]
        original_document = policy["document"]

        # b. Bedrock で最小権限ポリシー生成
        bedrock_result = bedrock.generate_least_privilege_policy(
            role_arn=role_arn,
            current_policy=original_document,
            unused_actions=all_unused_actions,
            last_accessed=last_accessed,
        )

        if bedrock_result is None:
            logger.warning(
                "Bedrock 生成失敗（スキップ）: role=%s policy=%s", role_arn, policy_name
            )
            continue

        revised_policy = bedrock_result["revised_policy"]
        removed_actions = bedrock_result["removed_actions"]
        reason = bedrock_result["reason"]
        warnings = bedrock_result["warnings"]

        # c. AI 出力検証
        # AI出力検証: validate_ai_policy で5項目すべてをチェックする
        is_valid, error_msg = validate_ai_policy(
            original_policy=original_document,
            revised_policy=revised_policy,
            unused_actions=all_unused_actions,
        )
        if not is_valid:
            logger.warning(
                "AI 出力検証失敗（スキップ）: role=%s policy=%s reason=%s",
                role_arn,
                policy_name,
                error_msg,
            )
            continue

        if not removed_actions:
            logger.info(
                "削除アクションなし（スキップ）: role=%s policy=%s", role_arn, policy_name
            )
            continue

        # d. Terraform HCL 変換
        hcl = TerraformFormatter.format_as_terraform(
            policy_name=policy_name,
            policy_arn=policy_arn,
            revised_policy=revised_policy,
            reason=reason,
            removed_actions=removed_actions,
        )

        # e. GitHub PR 作成（失敗時は raise して Lambda エラーとして記録）
        pr_url = pr_creator.create_pr(
            role_arn=role_arn,
            role_name=role_name,
            terraform_hcl=hcl,
            removed_actions=removed_actions,
            reason=reason,
            warnings=warnings,
            scan_date=scan_date,
        )

        # f. Chatwork 通知（失敗時はログのみ）
        notifier.notify_pr_created(
            role_name=role_name,
            removed_count=len(removed_actions),
            pr_url=pr_url,
            scan_date=scan_date,
        )

        pr_created_any = True
        logger.info(
            "PR 作成完了: role=%s policy=%s pr=%s", role_arn, policy_name, pr_url
        )

    return pr_created_any


def _stmt_key(stmt: dict) -> str:
    """
    Statement の一意キーを生成して返す。

    Sid がある場合はそれを使用し、なければ Effect+Action+Resource の連結を使用する。

    Args:
        stmt: IAM ポリシーの Statement 辞書

    Returns:
        Statement を識別するキー文字列
    """
    if stmt.get("Sid"):
        return stmt["Sid"]
    effect = stmt.get("Effect", "")
    action = json.dumps(stmt.get("Action", []), sort_keys=True)
    resource = json.dumps(stmt.get("Resource", []), sort_keys=True)
    return f"{effect}::{action}::{resource}"


def _normalize_actions(actions: str | list[str]) -> set[str]:
    """
    Action フィールドを小文字の set に正規化して返す。

    Action は文字列またはリストの両形式が許容されるため、どちらでも扱えるようにする。

    Args:
        actions: IAM Statement の Action 値（文字列またはリスト）

    Returns:
        小文字に正規化されたアクション名の set
    """
    if isinstance(actions, str):
        return {actions.lower()}
    return {a.lower() for a in actions}
