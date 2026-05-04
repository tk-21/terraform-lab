#!/usr/bin/env python3
"""
メールヘッダー解析スクリプト

Gmailなどで「メッセージのソースを表示」して取得したヘッダーを
わかりやすく解析・表示する学習ツール。

使用方法:
  # ヘッダーをファイルに保存してから
  python3 scripts/analyze-mail-header.py --file email-header.txt

  # 標準入力から
  cat email-header.txt | python3 scripts/analyze-mail-header.py
"""

import argparse
import email
import email.policy
import re
import sys
from datetime import datetime


def color(text: str, code: str) -> str:
    """ANSIカラーコードでテキストを装飾する"""
    colors = {
        "green": "\033[92m",
        "red": "\033[91m",
        "yellow": "\033[93m",
        "blue": "\033[94m",
        "cyan": "\033[96m",
        "bold": "\033[1m",
        "reset": "\033[0m",
    }
    return f"{colors.get(code, '')}{text}{colors['reset']}"


def print_section(title: str) -> None:
    print(f"\n{color('=' * 60, 'blue')}")
    print(color(f"  {title}", "bold"))
    print(color('=' * 60, 'blue'))


def parse_auth_results(header_value: str) -> dict:
    """Authentication-Resultsヘッダーを構造化データに変換する"""
    results = {}

    # SPF結果を抽出
    spf_match = re.search(r'spf=(\S+)', header_value, re.IGNORECASE)
    if spf_match:
        results["spf"] = {"result": spf_match.group(1)}
        smtp_from = re.search(r'smtp\.mailfrom=(\S+)', header_value, re.IGNORECASE)
        if smtp_from:
            results["spf"]["smtp_from"] = smtp_from.group(1)

    # DKIM結果を抽出
    dkim_matches = re.finditer(r'dkim=(\S+)[^;]*(?:header\.d=(\S+))?(?:[^;]*header\.i=(\S+))?(?:[^;]*header\.s=(\S+))?', header_value, re.IGNORECASE)
    dkim_list = []
    for m in dkim_matches:
        entry = {"result": m.group(1)}
        if m.group(2):
            entry["domain"] = m.group(2).rstrip(";")
        # セレクタを別途抽出
        s_match = re.search(r'header\.s=(\S+)', header_value, re.IGNORECASE)
        if s_match:
            entry["selector"] = s_match.group(1).rstrip(";")
        dkim_list.append(entry)
    if dkim_list:
        results["dkim"] = dkim_list

    # DMARC結果を抽出
    dmarc_match = re.search(r'dmarc=(\S+)', header_value, re.IGNORECASE)
    if dmarc_match:
        results["dmarc"] = {"result": dmarc_match.group(1)}
        policy_match = re.search(r'(?:p=|policy=)(\S+)', header_value, re.IGNORECASE)
        if policy_match:
            results["dmarc"]["policy"] = policy_match.group(1).rstrip(";")
        from_match = re.search(r'header\.from=(\S+)', header_value, re.IGNORECASE)
        if from_match:
            results["dmarc"]["header_from"] = from_match.group(1).rstrip(";")

    return results


def result_badge(result: str) -> str:
    """認証結果にカラーバッジを付ける"""
    result_lower = result.lower().rstrip(";")
    if result_lower == "pass":
        return color("✅ pass", "green")
    elif result_lower in ("fail", "hardfail"):
        return color("❌ fail", "red")
    elif result_lower in ("softfail", "neutral", "permerror", "temperror"):
        return color(f"⚠️  {result_lower}", "yellow")
    elif result_lower == "none":
        return color("ℹ️  none", "cyan")
    return color(result_lower, "yellow")


def analyze_alignment(from_domain: str, spf_domain: str, dkim_domain: str) -> None:
    """SPF/DKIMアライメント（Fromヘッダーとの一致）を判定して表示する"""
    print_section("アライメント判定（DMARCの核心）")
    print(f"  From ドメイン     : {color(from_domain, 'bold')}")
    print(f"  SPF 送信元ドメイン: {spf_domain}")
    print(f"  DKIM 署名ドメイン : {dkim_domain}")
    print()

    def domains_aligned(d1: str, d2: str) -> bool:
        # relaxedアライメント: 組織ドメイン（サブドメイン除く）が一致すればOK
        d1_parts = d1.lower().lstrip("@").split(".")
        d2_parts = d2.lower().lstrip("@").split(".")
        # 末尾2セグメント（example.com）を比較
        return d1_parts[-2:] == d2_parts[-2:]

    spf_aligned = domains_aligned(from_domain, spf_domain) if spf_domain else False
    dkim_aligned = domains_aligned(from_domain, dkim_domain) if dkim_domain else False

    spf_label = color("✅ アライメントOK (relaxed)", "green") if spf_aligned else color("❌ アライメント不一致", "red")
    dkim_label = color("✅ アライメントOK (relaxed)", "green") if dkim_aligned else color("❌ アライメント不一致", "red")

    print(f"  SPF アライメント  : {spf_label}")
    print(f"  DKIM アライメント : {dkim_label}")
    print()

    if spf_aligned or dkim_aligned:
        print(f"  {color('→ DMARC: いずれか1つがPassかつアライメントOKのため PASS', 'green')}")
    else:
        print(f"  {color('→ DMARC: 両方がアライメント不一致のため FAIL（DMARCポリシーが適用される）', 'red')}")


def print_received_chain(received_headers: list) -> None:
    """Receivedヘッダーを配送経路として時系列（古い順）に表示する"""
    print_section("メール配送経路（Receivedヘッダー）")
    print("  メールが辿ったMTAのホップを古い順（送信元→受信先）に表示します\n")

    # Receivedヘッダーは新しい順に並んでいるため逆順にする
    for i, received in enumerate(reversed(received_headers), 1):
        # 改行を除去して1行に整形
        clean = " ".join(received.split())
        from_match = re.search(r'from\s+(\S+)', clean, re.IGNORECASE)
        by_match = re.search(r'by\s+(\S+)', clean, re.IGNORECASE)
        date_match = re.search(r';\s*(.+)$', clean)

        hop_from = from_match.group(1) if from_match else "不明"
        hop_by = by_match.group(1) if by_match else "不明"
        hop_date = date_match.group(1).strip() if date_match else ""

        print(f"  [{i}] {color(hop_from, 'cyan')} → {color(hop_by, 'green')}")
        if hop_date:
            print(f"       受信時刻: {hop_date}")
        print()


def analyze(raw_header: str) -> None:
    """メールヘッダー全体を解析してセクションごとに表示する"""
    # ヘッダーのみのパース（本文なし）
    msg = email.message_from_string(raw_header, policy=email.policy.default)

    print(color("\n📧 メールヘッダー解析レポート", "bold"))
    print(color(f"   解析日時: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", "cyan"))

    # ============================================================
    # 基本情報
    # ============================================================
    print_section("基本情報")
    from_header = msg.get("From", "なし")
    to_header = msg.get("To", "なし")
    subject = msg.get("Subject", "なし")
    date = msg.get("Date", "なし")
    return_path = msg.get("Return-Path", "なし")
    message_id = msg.get("Message-ID", "なし")

    print(f"  From       : {color(from_header, 'bold')}")
    print(f"  To         : {to_header}")
    print(f"  Subject    : {subject}")
    print(f"  Date       : {date}")
    print(f"  Return-Path: {color(return_path, 'yellow')}")
    print(f"  Message-ID : {message_id}")

    # Return-PathとFromの比較（SPFアライメント学習ポイント）
    print()
    print(color("  【学習ポイント】", "cyan"))
    print("  Return-Path（SMTP MAIL FROM）はバウンスメールの宛先であり、")
    print("  SPFはこのドメインを検証します。FromヘッダーのドメインとReturn-Pathの")
    print("  ドメインが一致しない場合、SPFアライメントに注意が必要です。")

    # ============================================================
    # 配送経路
    # ============================================================
    received_headers = msg.get_all("Received") or []
    if received_headers:
        print_received_chain(received_headers)

    # ============================================================
    # SPF / DKIM / DMARC 認証結果
    # ============================================================
    print_section("メール認証結果（SPF / DKIM / DMARC）")

    auth_results_headers = msg.get_all("Authentication-Results") or []
    if not auth_results_headers:
        print(color("  ⚠️  Authentication-Results ヘッダーが見つかりません", "yellow"))
        print("  （受信MTAが挿入するヘッダーです。送信専用テストでは表示されません）")
    else:
        spf_domain = ""
        dkim_domain = ""
        for auth_value in auth_results_headers:
            auth_server_match = re.match(r'\s*(\S+)', auth_value)
            auth_server = auth_server_match.group(1) if auth_server_match else "不明"
            print(f"\n  検証サーバー: {color(auth_server, 'cyan')}")

            parsed = parse_auth_results(auth_value)

            if "spf" in parsed:
                spf = parsed["spf"]
                print(f"  SPF  : {result_badge(spf['result'])}")
                if "smtp_from" in spf:
                    print(f"         送信元(MAIL FROM): {spf['smtp_from']}")
                    spf_domain = spf["smtp_from"]
                print("         【解説】SESが送信元として登録したIPがSPFレコードに含まれているか検証")

            if "dkim" in parsed:
                for dkim in parsed["dkim"]:
                    print(f"  DKIM : {result_badge(dkim['result'])}")
                    if "domain" in dkim:
                        print(f"         署名ドメイン(d=): {dkim['domain']}")
                        dkim_domain = dkim["domain"]
                    if "selector" in dkim:
                        print(f"         セレクタ(s=)   : {dkim['selector']}")
                    print("         【解説】秘密鍵で署名されたハッシュをDNSの公開鍵で検証")

            if "dmarc" in parsed:
                dmarc = parsed["dmarc"]
                print(f"  DMARC: {result_badge(dmarc['result'])}")
                if "policy" in dmarc:
                    print(f"         適用ポリシー : {dmarc['policy']}")
                if "header_from" in dmarc:
                    print(f"         From ドメイン: {dmarc['header_from']}")
                print("         【解説】SPF/DKIMの結果とFromヘッダーのアライメントを総合判定")

        # アライメント解析（Fromドメインが取得できた場合）
        from_domain_match = re.search(r'@([\w.-]+)', from_header)
        from_domain = from_domain_match.group(1) if from_domain_match else ""
        if from_domain and (spf_domain or dkim_domain):
            analyze_alignment(from_domain, spf_domain, dkim_domain)

    # ============================================================
    # DKIM-Signature ヘッダーの詳細
    # ============================================================
    print_section("DKIM-Signature ヘッダー（署名の詳細）")
    dkim_sigs = msg.get_all("DKIM-Signature") or []
    if not dkim_sigs:
        print(color("  ⚠️  DKIM-Signature ヘッダーが見つかりません", "yellow"))
        print("  SESでDKIM署名が有効になっているか確認してください")
    else:
        for i, sig in enumerate(dkim_sigs, 1):
            print(f"\n  --- 署名 {i} ---")
            fields = {
                "v": "バージョン",
                "a": "署名アルゴリズム",
                "c": "正規化アルゴリズム",
                "d": "署名ドメイン",
                "s": "セレクタ（DNSキー参照先）",
                "h": "署名対象ヘッダー",
                "bh": "本文ハッシュ",
            }
            for key, label in fields.items():
                match = re.search(rf'\b{key}=([^;]+)', sig)
                if match:
                    value = match.group(1).strip()
                    if key == "bh":
                        value = value[:30] + "..." if len(value) > 30 else value
                    print(f"  {label:30s}: {value}")

        print()
        print(color("  【学習ポイント】", "cyan"))
        print("  s=（セレクタ）と d=（ドメイン）を使って以下のDNSを引けば公開鍵が確認できます:")
        for sig in dkim_sigs:
            s_match = re.search(r'\bs=([^;]+)', sig)
            d_match = re.search(r'\bd=([^;]+)', sig)
            if s_match and d_match:
                selector = s_match.group(1).strip()
                domain = d_match.group(1).strip()
                print(f"  dig TXT {selector}._domainkey.{domain}")

    # ============================================================
    # X-SES-* ヘッダー（SES固有情報）
    # ============================================================
    ses_headers = {k: v for k, v in msg.items() if k.lower().startswith("x-ses-")}
    if ses_headers:
        print_section("X-SES-* ヘッダー（SES固有情報）")
        for k, v in ses_headers.items():
            print(f"  {k}: {v}")
        print()
        print(color("  【解説】", "cyan"))
        print("  X-SES-DKIM-SIGNATURE: SESが付与したDKIM署名の状態")
        print("  X-SES-RECEIPT: SES受信ルールの処理結果")

    # ============================================================
    # 問題点と改善提案
    # ============================================================
    print_section("診断サマリーと改善提案")
    issues = []
    suggestions = []

    if not dkim_sigs:
        issues.append("DKIM-Signatureヘッダーがありません")
        suggestions.append("SES Console → Email Identities → DKIM → Enable DKIM signing を確認")

    if not auth_results_headers:
        suggestions.append("Gmailなど実際の受信サーバーに送信してAuthentication-Resultsを確認してください")

    if issues:
        print(color("  ⚠️  検出された問題:", "yellow"))
        for issue in issues:
            print(f"     - {issue}")
    else:
        print(color("  ✅ 明らかな問題は検出されませんでした", "green"))

    if suggestions:
        print(color("\n  💡 改善提案:", "cyan"))
        for suggestion in suggestions:
            print(f"     - {suggestion}")

    print()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="メールヘッダーを解析してSPF/DKIM/DMARCの認証結果をわかりやすく表示する"
    )
    parser.add_argument("--file", "-f", help="解析するメールヘッダーファイルのパス")
    args = parser.parse_args()

    if args.file:
        with open(args.file, "r", encoding="utf-8", errors="replace") as f:
            raw_header = f.read()
    elif not sys.stdin.isatty():
        raw_header = sys.stdin.read()
    else:
        print("使用方法: python3 analyze-mail-header.py --file email-header.txt")
        print("         または: cat email-header.txt | python3 analyze-mail-header.py")
        sys.exit(1)

    analyze(raw_header)


if __name__ == "__main__":
    main()
