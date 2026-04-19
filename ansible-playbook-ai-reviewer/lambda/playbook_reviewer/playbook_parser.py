"""
Ansible PlaybookのYAML解析・コンテキスト抽出モジュール
BedrockへのPROMPT構築のためにPlaybookの構造を分析する
"""

import re
import yaml
from typing import Any

# 事前スキャンで検出する危険パターン
DANGEROUS_PATTERNS = {
    "no_log_missing": "パスワードや秘密情報を扱うタスクにno_logが設定されていない",
    "shell_overuse": "shell/commandモジュールが多用されている（冪等性リスク）",
    "become_unnecessary": "become: yesが不必要に使用されている可能性",
    "hardcoded_secrets": "ハードコードされた認証情報の可能性",
    "ignore_errors_overuse": "ignore_errors: trueが多用されている",
    "deprecated_with_items": "非推奨のwith_itemsが使用されている（loopを推奨）",
}

# タスクディクショナリ中のモジュール名ではないキー
_NON_MODULE_KEYS = frozenset({
    "name", "when", "register", "become", "become_user", "no_log",
    "ignore_errors", "changed_when", "failed_when", "tags", "loop",
    "loop_control", "with_items", "with_list", "with_dict", "with_fileglob",
    "notify", "vars", "block", "rescue", "always", "environment",
    "delegate_to", "run_once", "any_errors_fatal", "listen", "include_tasks",
    "import_tasks", "include_role", "import_role", "set_fact", "debug",
    "meta", "pause",
})

# 秘密情報を扱う可能性があるキーワード
_SECRET_KEYWORDS = re.compile(r"password|passwd|secret|token|key|credential|api_key", re.IGNORECASE)


def parse_playbook(yaml_content: str) -> dict:
    """
    Ansible PlaybookのYAMLをパースして構造化データを返す

    - 無効なYAMLはparse_errorsに追加して返す（例外を外部に投げない）
    - 空のPlaybookも正常に処理する
    """
    result: dict = {
        "plays": [],
        "statistics": {
            "total_tasks": 0,
            "total_plays": 0,
            "modules_used": [],
            "has_handlers": False,
            "has_tags": False,
            "uses_roles": False,
        },
        "pre_scan_warnings": [],
        "parse_errors": [],
    }

    if not yaml_content or not yaml_content.strip():
        return result

    try:
        raw = yaml.safe_load(yaml_content)
    except yaml.YAMLError as e:
        result["parse_errors"].append(f"YAMLパースエラー: {e}")
        return result

    if not isinstance(raw, list):
        result["parse_errors"].append("PlaybookはYAMLリスト形式である必要があります")
        return result

    all_modules: set[str] = set()
    all_tasks_count = 0

    for play_raw in raw:
        if not isinstance(play_raw, dict):
            continue

        play: dict = {
            "name": play_raw.get("name", ""),
            "hosts": play_raw.get("hosts", ""),
            "become": bool(play_raw.get("become", False)),
            "gather_facts": play_raw.get("gather_facts", True),
            "tasks": [],
            "handlers": [],
            "vars": play_raw.get("vars", {}),
            "roles": play_raw.get("roles", []),
        }

        # タスク解析
        for task_raw in play_raw.get("tasks", []):
            parsed_task = _parse_task(task_raw)
            play["tasks"].append(parsed_task)
            if parsed_task["module"]:
                all_modules.add(parsed_task["module"])
            all_tasks_count += 1

            # block内タスクも処理
            if "block" in task_raw:
                for block_task in task_raw.get("block", []):
                    bt = _parse_task(block_task)
                    play["tasks"].append(bt)
                    if bt["module"]:
                        all_modules.add(bt["module"])
                    all_tasks_count += 1
                for block_task in task_raw.get("rescue", []):
                    bt = _parse_task(block_task)
                    play["tasks"].append(bt)
                    if bt["module"]:
                        all_modules.add(bt["module"])
                    all_tasks_count += 1

        # ハンドラー解析
        for handler_raw in play_raw.get("handlers", []):
            play["handlers"].append(_parse_task(handler_raw))

        result["plays"].append(play)

    all_plays = result["plays"]
    result["statistics"] = {
        "total_tasks": all_tasks_count,
        "total_plays": len(all_plays),
        "modules_used": sorted(all_modules),
        "has_handlers": any(len(p["handlers"]) > 0 for p in all_plays),
        "has_tags": any(
            any(t["tags"] for t in p["tasks"]) for p in all_plays
        ),
        "uses_roles": any(len(p["roles"]) > 0 for p in all_plays),
    }
    result["pre_scan_warnings"] = scan_for_dangerous_patterns(all_plays)

    return result


def _parse_task(task_dict: dict) -> dict:
    """タスクディクショナリを構造化データへ変換する"""
    if not isinstance(task_dict, dict):
        return {
            "name": "", "module": "", "args": {}, "become": False,
            "no_log": False, "ignore_errors": False, "changed_when": None,
            "failed_when": None, "tags": [], "loop": None,
            "with_items": None, "register": "",
        }
    return {
        "name": task_dict.get("name", ""),
        "module": detect_module_name(task_dict),
        "args": _extract_module_args(task_dict),
        "become": bool(task_dict.get("become", False)),
        "no_log": bool(task_dict.get("no_log", False)),
        "ignore_errors": bool(task_dict.get("ignore_errors", False)),
        "changed_when": task_dict.get("changed_when"),
        "failed_when": task_dict.get("failed_when"),
        "tags": task_dict.get("tags", []),
        "loop": task_dict.get("loop"),
        "with_items": task_dict.get("with_items"),
        "register": task_dict.get("register", ""),
    }


def _extract_module_args(task_dict: dict) -> dict:
    """タスクdictからモジュール引数を抽出する"""
    module_name = detect_module_name(task_dict)
    if not module_name:
        return {}
    args = task_dict.get(module_name, {})
    if isinstance(args, str):
        return {"_raw": args}
    if isinstance(args, dict):
        return args
    return {}


def detect_module_name(task_dict: dict) -> str:
    """
    タスクディクショナリからモジュール名を特定する
    ansible.builtin.shell, shell, community.general.xxx など様々な形式に対応
    """
    if not isinstance(task_dict, dict):
        return ""
    for key in task_dict:
        if key not in _NON_MODULE_KEYS:
            return key
    return ""


def scan_for_dangerous_patterns(plays: list) -> list[dict]:
    """
    DANGEROUS_PATTERNSに基づいてPlaybook全体をスキャンする
    事前にBedrockへ送る前に明確な問題を検出する
    """
    warnings: list[dict] = []

    shell_locations: list[str] = []
    ignore_errors_locations: list[str] = []
    with_items_locations: list[str] = []
    no_log_missing_locations: list[str] = []
    hardcoded_locations: list[str] = []

    for play in plays:
        for task in play.get("tasks", []):
            module = task.get("module", "")
            task_name = task.get("name", module or "（名前なし）")
            args = task.get("args", {})

            # shell/commandモジュールの多用チェック
            short_module = module.split(".")[-1] if module else ""
            if short_module in ("shell", "command", "raw"):
                shell_locations.append(task_name)

            # no_log未設定で秘密情報を扱うタスクチェック
            if not task.get("no_log"):
                args_str = str(args).lower()
                if _SECRET_KEYWORDS.search(args_str) or _SECRET_KEYWORDS.search(task_name):
                    no_log_missing_locations.append(task_name)

            # ハードコードされた認証情報チェック（password=xxx 形式）
            args_str = str(args)
            if re.search(r"(password|passwd|secret)\s*=\s*['\"]?[^{}\s'\"][^{}\s'\"]{3,}", args_str, re.IGNORECASE):
                hardcoded_locations.append(task_name)

            # ignore_errors多用チェック
            if task.get("ignore_errors"):
                ignore_errors_locations.append(task_name)

            # 非推奨with_itemsチェック
            if task.get("with_items") is not None:
                with_items_locations.append(task_name)

    if len(shell_locations) >= 3:
        warnings.append({
            "pattern": "shell_overuse",
            "locations": shell_locations,
            "severity": "MEDIUM",
        })

    if no_log_missing_locations:
        warnings.append({
            "pattern": "no_log_missing",
            "locations": no_log_missing_locations,
            "severity": "HIGH",
        })

    if hardcoded_locations:
        warnings.append({
            "pattern": "hardcoded_secrets",
            "locations": hardcoded_locations,
            "severity": "CRITICAL",
        })

    if len(ignore_errors_locations) >= 2:
        warnings.append({
            "pattern": "ignore_errors_overuse",
            "locations": ignore_errors_locations,
            "severity": "MEDIUM",
        })

    if with_items_locations:
        warnings.append({
            "pattern": "deprecated_with_items",
            "locations": with_items_locations,
            "severity": "LOW",
        })

    return warnings
