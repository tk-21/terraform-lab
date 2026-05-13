#!/usr/bin/env python3
"""
Istio サービスメッシュ観測レポート生成スクリプト
EKS クラスタの状態と Istio 設定を HTML レポートとして S3 に保存する
"""

import subprocess
import json
import boto3
import datetime
import os
import sys
from typing import Any


def run_kubectl(args: list[str]) -> dict | list | None:
    """kubectl コマンドを実行して JSON でパースした結果を返す"""
    cmd = ["kubectl"] + args + ["-o", "json"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  警告: kubectl {' '.join(args)} が失敗しました: {result.stderr.strip()}", file=sys.stderr)
        return None
    return json.loads(result.stdout)


def run_command(cmd: list[str]) -> str:
    """汎用コマンド実行（標準出力を文字列で返す）"""
    result = subprocess.run(cmd, capture_output=True, text=True)
    return result.stdout.strip()


def collect_kubectl_data() -> dict[str, Any]:
    """kubectl コマンドで必要なデータを収集する"""
    data: dict[str, Any] = {}

    data["nodes"] = run_kubectl(["get", "nodes"])
    data["mesh_pods"] = run_kubectl(["get", "pods", "-n", "mesh-apps"])
    data["istio_pods"] = run_kubectl(["get", "pods", "-n", "istio-system"])
    data["virtual_services"] = run_kubectl(["get", "virtualservice", "-n", "mesh-apps"])
    data["destination_rules"] = run_kubectl(["get", "destinationrule", "-n", "mesh-apps"])
    data["gateways"] = run_kubectl(["get", "gateway", "-n", "mesh-apps"])
    data["peer_authentications"] = run_kubectl(["get", "peerauthentication", "-A"])

    # istioctl による mTLS 状態チェック（失敗しても続行）
    tls_result = subprocess.run(
        ["istioctl", "authn", "tls-check", "-n", "mesh-apps"],
        capture_output=True, text=True
    )
    data["tls_check"] = tls_result.stdout.strip() if tls_result.returncode == 0 else "istioctl が利用できません"

    # Istio バージョン取得
    version_result = subprocess.run(
        ["istioctl", "version", "--remote=false"],
        capture_output=True, text=True
    )
    data["istio_version"] = version_result.stdout.strip().replace("client version: ", "")

    return data


def _pod_status_badge(phase: str) -> str:
    """Pod ステータスに応じたカラーバッジ HTML を返す"""
    colors = {
        "Running": ("#238636", "#3fb950"),
        "Pending": ("#9e6a03", "#d29922"),
        "Failed": ("#8d0f0f", "#f85149"),
        "Succeeded": ("#1f6feb", "#58a6ff"),
    }
    bg, text = colors.get(phase, ("#30363d", "#8b949e"))
    return (
        f'<span style="background:{bg};color:{text};padding:2px 8px;'
        f'border-radius:12px;font-size:12px;font-weight:600;">{phase}</span>'
    )


def _canary_weight_bar(v1_weight: int, v2_weight: int) -> str:
    """カナリア重みを水平プログレスバーで表示する HTML を返す"""
    return f"""
    <div style="margin:8px 0;">
      <div style="display:flex;align-items:center;gap:8px;margin-bottom:4px;">
        <span style="width:80px;font-size:13px;">v1 ({v1_weight}%)</span>
        <div style="flex:1;background:#21262d;border-radius:4px;height:16px;">
          <div style="width:{v1_weight}%;background:#1f6feb;height:16px;border-radius:4px;"></div>
        </div>
      </div>
      <div style="display:flex;align-items:center;gap:8px;">
        <span style="width:80px;font-size:13px;">v2 ({v2_weight}%)</span>
        <div style="flex:1;background:#21262d;border-radius:4px;height:16px;">
          <div style="width:{v2_weight}%;background:#388bfd;height:16px;border-radius:4px;"></div>
        </div>
      </div>
    </div>"""


def _extract_canary_weights(data: dict) -> dict[str, tuple[int, int]]:
    """VirtualService から各サービスのカナリア重みを抽出する"""
    weights: dict[str, tuple[int, int]] = {}
    vs_data = data.get("virtual_services")
    if not vs_data or "items" not in vs_data:
        return weights

    for vs in vs_data["items"]:
        name = vs["metadata"]["name"]
        routes = vs.get("spec", {}).get("http", [])
        if not routes:
            continue
        destinations = routes[0].get("route", [])
        v_weights: dict[str, int] = {}
        for dest in destinations:
            subset = dest.get("destination", {}).get("subset", "unknown")
            w = dest.get("weight", 0)
            v_weights[subset] = w
        if "v1" in v_weights or "v2" in v_weights:
            weights[name] = (v_weights.get("v1", 0), v_weights.get("v2", 0))

    return weights


def _extract_circuit_breaker(data: dict) -> list[dict]:
    """DestinationRule からサーキットブレーカー設定を抽出する"""
    configs = []
    dr_data = data.get("destination_rules")
    if not dr_data or "items" not in dr_data:
        return configs

    for dr in dr_data["items"]:
        od = dr.get("spec", {}).get("trafficPolicy", {}).get("outlierDetection")
        if od:
            configs.append({
                "name": dr["metadata"]["name"],
                "consecutive5xxErrors": od.get("consecutive5xxErrors", "-"),
                "interval": od.get("interval", "-"),
                "baseEjectionTime": od.get("baseEjectionTime", "-"),
                "maxEjectionPercent": od.get("maxEjectionPercent", "-"),
            })
    return configs


def generate_html_report(data: dict) -> str:
    """収集したデータを HTML レポートに変換する（CSS インライン・ダークテーマ）"""
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S JST")
    canary_weights = _extract_canary_weights(data)
    circuit_breakers = _extract_circuit_breaker(data)

    # --- ノード情報 ---
    node_rows = ""
    nodes = data.get("nodes")
    if nodes and "items" in nodes:
        for node in nodes["items"]:
            name = node["metadata"]["name"]
            conditions = node.get("status", {}).get("conditions", [])
            ready = next((c for c in conditions if c["type"] == "Ready"), {})
            status = "Ready" if ready.get("status") == "True" else "NotReady"
            badge = _pod_status_badge("Running" if status == "Ready" else "Failed")
            labels = node["metadata"].get("labels", {})
            instance_type = labels.get("node.kubernetes.io/instance-type", "-")
            arch = labels.get("kubernetes.io/arch", "-")
            node_rows += f"<tr><td>{name}</td><td>{badge}</td><td>{instance_type}</td><td>{arch}</td></tr>\n"

    # --- Pod 情報（mesh-apps） ---
    pod_rows = ""
    mesh_pods = data.get("mesh_pods")
    if mesh_pods and "items" in mesh_pods:
        for pod in mesh_pods["items"]:
            name = pod["metadata"]["name"]
            phase = pod.get("status", {}).get("phase", "Unknown")
            containers = pod.get("status", {}).get("containerStatuses", [])
            ready_count = sum(1 for c in containers if c.get("ready"))
            total_count = len(containers)
            restarts = sum(c.get("restartCount", 0) for c in containers)
            start_time = pod.get("status", {}).get("startTime", "-")
            badge = _pod_status_badge(phase)
            pod_rows += (
                f"<tr><td>{name}</td><td>{badge}</td>"
                f"<td>{ready_count}/{total_count}</td>"
                f"<td>{restarts}</td><td>{start_time}</td></tr>\n"
            )

    # --- カナリア重みセクション ---
    canary_html = ""
    for svc_name, (v1_w, v2_w) in canary_weights.items():
        canary_html += f"<h4 style='margin:12px 0 4px;color:#58a6ff;'>{svc_name}</h4>"
        canary_html += _canary_weight_bar(v1_w, v2_w)

    if not canary_html:
        canary_html = "<p style='color:#8b949e;'>VirtualService が見つかりません</p>"

    # --- サーキットブレーカーセクション ---
    cb_rows = ""
    for cb in circuit_breakers:
        cb_rows += (
            f"<tr><td>{cb['name']}</td>"
            f"<td>{cb['consecutive5xxErrors']}</td>"
            f"<td>{cb['interval']}</td>"
            f"<td>{cb['baseEjectionTime']}</td>"
            f"<td>{cb['maxEjectionPercent']}%</td></tr>\n"
        )
    if not cb_rows:
        cb_rows = "<tr><td colspan='5' style='text-align:center;color:#8b949e;'>設定なし</td></tr>"

    # --- mTLS チェック結果 ---
    tls_output = data.get("tls_check", "データなし")
    tls_html = f"<pre style='background:#161b22;padding:16px;border-radius:6px;overflow-x:auto;font-size:12px;'>{tls_output}</pre>"

    # --- Istio リソース一覧 ---
    def resource_list_html(items_data: dict | None, kind: str) -> str:
        if not items_data or "items" not in items_data:
            return f"<p style='color:#8b949e;'>{kind} が見つかりません</p>"
        rows = ""
        for item in items_data["items"]:
            name = item["metadata"]["name"]
            ns = item["metadata"].get("namespace", "-")
            rows += f"<tr><td>{name}</td><td>{ns}</td></tr>\n"
        return (
            f"<table style='width:100%;border-collapse:collapse;'>"
            f"<thead><tr><th>名前</th><th>Namespace</th></tr></thead>"
            f"<tbody>{rows}</tbody></table>"
        )

    istio_resources_html = ""
    for kind_key, label in [
        ("virtual_services", "VirtualService"),
        ("destination_rules", "DestinationRule"),
        ("gateways", "Gateway"),
        ("peer_authentications", "PeerAuthentication"),
    ]:
        istio_resources_html += f"<h4 style='color:#58a6ff;margin:16px 0 8px;'>{label}</h4>"
        istio_resources_html += resource_list_html(data.get(kind_key), label)

    # --- HTML 全体 ---
    html = f"""<!DOCTYPE html>
<html lang="ja">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Istio サービスメッシュ観測レポート</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      background: #0d1117;
      color: #e6edf3;
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
      line-height: 1.6;
      padding: 24px;
    }}
    .container {{ max-width: 1100px; margin: 0 auto; }}
    header {{ border-bottom: 1px solid #21262d; padding-bottom: 16px; margin-bottom: 24px; }}
    header h1 {{ font-size: 24px; color: #58a6ff; }}
    header p {{ color: #8b949e; font-size: 14px; margin-top: 4px; }}
    .grid {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 16px; margin-bottom: 24px; }}
    .stat-card {{
      background: #161b22;
      border: 1px solid #21262d;
      border-radius: 8px;
      padding: 16px;
    }}
    .stat-card .value {{ font-size: 28px; font-weight: 700; color: #58a6ff; }}
    .stat-card .label {{ font-size: 13px; color: #8b949e; margin-top: 4px; }}
    section {{
      background: #161b22;
      border: 1px solid #21262d;
      border-radius: 8px;
      padding: 20px;
      margin-bottom: 24px;
    }}
    section h2 {{ font-size: 18px; color: #e6edf3; margin-bottom: 16px; padding-bottom: 8px; border-bottom: 1px solid #21262d; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 14px; }}
    th, td {{ text-align: left; padding: 8px 12px; border-bottom: 1px solid #21262d; }}
    th {{ color: #8b949e; font-weight: 600; font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }}
    tr:last-child td {{ border-bottom: none; }}
    code {{ font-family: 'SFMono-Regular', Consolas, monospace; font-size: 13px; background: #21262d; padding: 2px 6px; border-radius: 4px; }}
    footer {{ text-align: center; color: #8b949e; font-size: 12px; margin-top: 32px; padding-top: 16px; border-top: 1px solid #21262d; }}
    @media (max-width: 600px) {{ body {{ padding: 12px; }} .grid {{ grid-template-columns: 1fr; }} }}
  </style>
</head>
<body>
<div class="container">
  <header>
    <h1>Istio サービスメッシュ観測レポート</h1>
    <p>生成日時: {now} &nbsp;|&nbsp; プロジェクト: istio-eks-service-mesh</p>
    <p style="margin-top:8px;color:#3fb950;">Istio バージョン: {data.get('istio_version', '不明')}</p>
  </header>

  <div class="grid">
    <div class="stat-card">
      <div class="value">{len(data.get('nodes', {}).get('items', []))}</div>
      <div class="label">EKS ノード数</div>
    </div>
    <div class="stat-card">
      <div class="value">{len(data.get('mesh_pods', {}).get('items', []))}</div>
      <div class="label">mesh-apps Pod 数</div>
    </div>
    <div class="stat-card">
      <div class="value">{len(data.get('istio_pods', {}).get('items', []))}</div>
      <div class="label">istio-system Pod 数</div>
    </div>
    <div class="stat-card">
      <div class="value">{len(data.get('virtual_services', {}).get('items', []))}</div>
      <div class="label">VirtualService 数</div>
    </div>
  </div>

  <section>
    <h2>EKS ノード状態</h2>
    <table>
      <thead><tr><th>ノード名</th><th>ステータス</th><th>インスタンスタイプ</th><th>アーキテクチャ</th></tr></thead>
      <tbody>{node_rows or '<tr><td colspan="4" style="text-align:center;color:#8b949e;">データなし</td></tr>'}</tbody>
    </table>
  </section>

  <section>
    <h2>mesh-apps Pod 状態</h2>
    <table>
      <thead><tr><th>Pod 名</th><th>ステータス</th><th>コンテナ Ready</th><th>再起動数</th><th>開始時刻</th></tr></thead>
      <tbody>{pod_rows or '<tr><td colspan="5" style="text-align:center;color:#8b949e;">Pod が見つかりません</td></tr>'}</tbody>
    </table>
  </section>

  <section>
    <h2>カナリアリリース設定</h2>
    {canary_html}
  </section>

  <section>
    <h2>サーキットブレーカー設定</h2>
    <table>
      <thead><tr><th>DestinationRule</th><th>連続5xxしきい値</th><th>検出ウィンドウ</th><th>除外時間</th><th>最大除外割合</th></tr></thead>
      <tbody>{cb_rows}</tbody>
    </table>
  </section>

  <section>
    <h2>Istio リソース一覧</h2>
    {istio_resources_html}
  </section>

  <section>
    <h2>mTLS 状態 (istioctl authn tls-check)</h2>
    {tls_html}
  </section>

  <footer>
    生成スクリプト: <code>scripts/generate_report.py</code> &nbsp;|&nbsp;
    プロジェクト: <code>istio-eks-service-mesh</code>
  </footer>
</div>
</body>
</html>"""
    return html


def upload_to_s3(html_content: str, bucket_name: str) -> str | None:
    """HTML レポートを S3 にアップロードし署名付き URL（7日間有効）を返す。失敗時は None。"""
    try:
        s3_client = boto3.client("s3", region_name="ap-northeast-1")
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d-%H-%M")
        key = f"reports/{timestamp}/index.html"

        s3_client.put_object(
            Bucket=bucket_name,
            Key=key,
            Body=html_content.encode("utf-8"),
            ContentType="text/html; charset=utf-8",
        )

        # 7日間有効な署名付き URL を生成（S3 バケットポリシーが公開設定でなくても閲覧可能）
        url = s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket_name, "Key": key},
            ExpiresIn=604800,  # 7日 = 604800 秒
        )
        return url
    except Exception as e:
        print(f"エラー: S3 アップロード失敗 - {e}", file=sys.stderr)
        return None


def main() -> None:
    bucket_name = os.environ.get("REPORT_BUCKET")
    if not bucket_name:
        raise ValueError("REPORT_BUCKET 環境変数が設定されていません")

    print("メッシュ状態データを収集中...")
    data = collect_kubectl_data()

    print("HTML レポートを生成中...")
    html = generate_html_report(data)

    print("S3 にアップロード中...")
    url = upload_to_s3(html, bucket_name)

    if url is None:
        print("レポート生成は完了しましたが、S3 アップロードに失敗しました", file=sys.stderr)
        sys.exit(1)

    print("レポート生成完了！")
    print(f"閲覧 URL（7日間有効）: {url}")


if __name__ == "__main__":
    main()
