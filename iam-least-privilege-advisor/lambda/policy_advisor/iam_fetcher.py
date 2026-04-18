"""
IamFetcher モジュール

IAM ロールにアタッチされたマネージドポリシーを取得する。
インラインポリシーは対象外とし、マネージドポリシーのみ扱う。
"""

import logging

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)


class IamFetcher:
    """IAM ロールのマネージドポリシーを取得するクライアント。"""

    def __init__(self, client=None):
        """
        初期化。

        Args:
            client: boto3 IAM クライアント（省略時は自動生成）
        """
        self._client = client or boto3.client("iam")

    def get_managed_policies(self, role_arn: str) -> list[dict]:
        """
        ロール ARN にアタッチされたマネージドポリシーの一覧とドキュメントを返す。

        IAM アクション:
          - iam:ListAttachedRolePolicies
          - iam:GetPolicy
          - iam:GetPolicyVersion

        インラインポリシーは対象外。ポリシー取得に失敗した場合はそのポリシーを
        スキップしてログを出力し、他のポリシーの処理を継続する。

        Args:
            role_arn: 対象 IAM ロールの ARN（例: arn:aws:iam::123456789012:role/my-role）

        Returns:
            [{"policy_name": str, "policy_arn": str, "document": dict}, ...]
            取得できたポリシーのみ含む。失敗分はスキップ。
        """
        role_name = self._role_name_from_arn(role_arn)
        attached = self._list_attached_policies(role_name)

        results = []
        for entry in attached:
            policy = self._fetch_policy_document(
                entry["PolicyName"], entry["PolicyArn"]
            )
            if policy:
                results.append(policy)

        logger.info(
            "ロール %s: マネージドポリシー %d 件取得（アタッチ数=%d）",
            role_name,
            len(results),
            len(attached),
        )
        return results

    # ------------------------------------------------------------------
    # 内部メソッド
    # ------------------------------------------------------------------

    def _role_name_from_arn(self, role_arn: str) -> str:
        """
        ロール ARN からロール名を抽出して返す。

        Args:
            role_arn: IAM ロールの ARN

        Returns:
            ロール名文字列
        """
        # ARN 形式: arn:aws:iam::<account_id>:role/<role_name>
        return role_arn.split("/")[-1]

    def _list_attached_policies(self, role_name: str) -> list[dict]:
        """
        ロールにアタッチされたマネージドポリシーの一覧を返す。

        IAM アクション: iam:ListAttachedRolePolicies

        Args:
            role_name: IAM ロール名

        Returns:
            [{"PolicyName": str, "PolicyArn": str}, ...] のリスト
        """
        policies = []
        # IAM アクション: iam:ListAttachedRolePolicies
        paginator = self._client.get_paginator("list_attached_role_policies")
        for page in paginator.paginate(RoleName=role_name):
            policies.extend(page.get("AttachedPolicies", []))
        return policies

    def _fetch_policy_document(
        self, policy_name: str, policy_arn: str
    ) -> dict | None:
        """
        ポリシー ARN から現行バージョンのポリシードキュメントを取得して返す。

        IAM アクション: iam:GetPolicy, iam:GetPolicyVersion

        取得に失敗した場合はエラーログを出力して None を返す。

        Args:
            policy_name: ポリシー名（ログ表示用）
            policy_arn: マネージドポリシーの ARN

        Returns:
            {"policy_name": str, "policy_arn": str, "document": dict}
            取得失敗時は None
        """
        try:
            # IAM アクション: iam:GetPolicy
            policy_resp = self._client.get_policy(PolicyArn=policy_arn)
            default_version_id = policy_resp["Policy"]["DefaultVersionId"]

            # IAM アクション: iam:GetPolicyVersion
            version_resp = self._client.get_policy_version(
                PolicyArn=policy_arn,
                VersionId=default_version_id,
            )
            document = version_resp["PolicyVersion"]["Document"]

            return {
                "policy_name": policy_name,
                "policy_arn": policy_arn,
                "document": document,
            }

        except ClientError as e:
            logger.warning(
                "ポリシー取得失敗（スキップ）: policy_arn=%s, error=%s",
                policy_arn,
                e.response["Error"]["Code"],
            )
            return None
