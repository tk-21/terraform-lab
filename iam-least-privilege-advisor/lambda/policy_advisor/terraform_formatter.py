"""
TerraformFormatter モジュール

IAM ポリシー JSON を Terraform の aws_iam_policy リソース（HCL）形式に変換する。
jsonencode() 形式を使用し、ヒアドキュメントは使用しない。
"""

import json
import logging

logger = logging.getLogger(__name__)


class TerraformFormatter:
    """IAM ポリシードキュメントを Terraform HCL 文字列に変換するフォーマッター。"""

    @staticmethod
    def format_as_terraform(
        policy_name: str,
        policy_arn: str,
        revised_policy: dict,
        reason: str,
        removed_actions: list[str],
    ) -> str:
        """
        IAM ポリシー JSON を Terraform aws_iam_policy リソースに変換して返す。

        出力仕様:
          - ファイル先頭に「# AI生成 - レビュー必須」コメントを記載する
          - 削除されたアクションと変更理由をコメントで記載する
          - policy 引数は jsonencode() 形式を使用する（ヒアドキュメント不可）
          - インデントはスペース 2 つ

        Args:
            policy_name: IAM ポリシー名（aws_iam_policy の name 属性に使用）
            policy_arn: IAM ポリシーの ARN（コメント記載用）
            revised_policy: 修正後の IAM ポリシードキュメント（dict）
            reason: Bedrock が生成した変更理由（日本語）
            removed_actions: 削除されたアクションの一覧

        Returns:
            Terraform HCL 形式の文字列
        """
        resource_label = TerraformFormatter._to_resource_label(policy_name)
        removed_comment = TerraformFormatter._format_removed_actions_comment(
            removed_actions
        )
        jsonencode_body = TerraformFormatter._dict_to_jsonencode(revised_policy, indent=4)

        lines = [
            "# AI生成 - レビュー必須",
            f"# 対象ポリシー ARN: {policy_arn}",
            f"# 削除されたアクション ({len(removed_actions)}件): {removed_comment}",
            f"# 変更理由: {reason}",
            "",
            f'resource "aws_iam_policy" "{resource_label}" {{',
            f'  name   = "{policy_name}"',
            f"  policy = jsonencode({jsonencode_body})",
            "}",
            "",
        ]

        return "\n".join(lines)

    # ------------------------------------------------------------------
    # 内部メソッド
    # ------------------------------------------------------------------

    @staticmethod
    def _to_resource_label(policy_name: str) -> str:
        """
        ポリシー名を Terraform リソースラベル（英数字とアンダースコアのみ）に変換する。

        Args:
            policy_name: IAM ポリシー名

        Returns:
            Terraform リソースラベル文字列
        """
        return policy_name.lower().replace("-", "_").replace(".", "_")

    @staticmethod
    def _format_removed_actions_comment(removed_actions: list[str]) -> str:
        """
        削除アクション一覧をコメント用のカンマ区切り文字列に変換して返す。

        Args:
            removed_actions: 削除されたアクションの一覧

        Returns:
            カンマ区切り文字列。空の場合は "(なし)"
        """
        return ", ".join(removed_actions) if removed_actions else "(なし)"

    @staticmethod
    def _dict_to_jsonencode(obj: dict | list | str | int | bool | None, indent: int) -> str:
        """
        Python オブジェクトを Terraform jsonencode() の引数形式（HCL 風）に変換する。

        Terraform の jsonencode() は JSON と同じ構造を受け取るが、
        HCL の慣習に従い = 記号なしのキー記法で記述する。

        Args:
            obj: 変換対象のオブジェクト
            indent: 現在のインデント幅（スペース数）

        Returns:
            HCL 風の jsonencode 引数文字列
        """
        pad = " " * indent
        inner_pad = " " * (indent + 2)

        if isinstance(obj, dict):
            if not obj:
                return "{}"
            items = []
            for k, v in obj.items():
                val_str = TerraformFormatter._dict_to_jsonencode(v, indent + 2)
                items.append(f"{inner_pad}{k} = {val_str}")
            body = "\n".join(items)
            return f"{{\n{body}\n{pad}}}"

        if isinstance(obj, list):
            if not obj:
                return "[]"
            items = [
                f"{inner_pad}{TerraformFormatter._dict_to_jsonencode(v, indent + 2)}"
                for v in obj
            ]
            body = ",\n".join(items)
            return f"[\n{body}\n{pad}]"

        if isinstance(obj, bool):
            return "true" if obj else "false"

        if isinstance(obj, (int, float)):
            return str(obj)

        if obj is None:
            return "null"

        # 文字列: JSON エンコードしてクォートを保持する
        return json.dumps(obj, ensure_ascii=False)
