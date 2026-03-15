import json
import re
from typing import List, Tuple, Dict

import boto3

def _short_source_from_s3_uri(uri: str) -> str:
    # s3://bucket/docs/vpn_setup.md -> docs/vpn_setup.md
    m = re.match(r"^s3://[^/]+/(.+)$", uri)
    return m.group(1) if m else uri

def retrieve(region: str, kb_id: str, query: str, k: int = 3) -> List[Dict]:
    client = boto3.client("bedrock-agent-runtime", region_name=region)

    resp = client.retrieve(
        knowledgeBaseId=kb_id,
        retrievalQuery={"text": query},
        retrievalConfiguration={
            "vectorSearchConfiguration": {"numberOfResults": k}
        },
    )

    results = []
    for r in resp.get("retrievalResults", []):
        text = r.get("content", {}).get("text", "")
        uri = (
            r.get("location", {})
             .get("s3Location", {})
             .get("uri", "")
        ) or r.get("metadata", {}).get("x-amz-bedrock-kb-source-uri", "")

        results.append({
            "text": text.strip(),
            "source_uri": uri,
            "source": _short_source_from_s3_uri(uri) if uri else "unknown",
            "score": r.get("score", None),
        })
    return results

def generate_with_claude(region: str, model_id: str, system: str, question: str, snippets: List[Dict]) -> str:
    """
    model_id は例: anthropic.claude-3-5-sonnet-20240620-v1:0
    """
    client = boto3.client("bedrock-runtime", region_name=region)

    # デモは「参照」を明示すると説得力が出る
    context_lines = []
    for i, s in enumerate(snippets, start=1):
        context_lines.append(f"[{i}] source: {s['source']}\n{s['text']}")
    context = "\n\n".join(context_lines)

    user_text = (
        f"質問: {question}\n\n"
        f"以下は社内ナレッジ検索結果（引用）です。\n"
        f"{context}\n\n"
        "指示:\n"
        "- 検索結果に書かれている範囲で回答してください（推測しない）。\n"
        "- 回答の最後に参照番号 [1][2]… を付けてください。\n"
    )

    body = {
        "anthropic_version": "bedrock-2023-05-31",
        "max_tokens": 800,
        "system": system,
        "messages": [
            {"role": "user", "content": [{"type": "text", "text": user_text}]}
        ],
    }

    resp = client.invoke_model(
        modelId=model_id,
        body=json.dumps(body).encode("utf-8"),
        accept="application/json",
        contentType="application/json",
    )
    payload = json.loads(resp["body"].read())
    return payload["content"][0]["text"]

def retrieve_and_generate(region: str, kb_id: str, _kb_model_arn_unused: str, question: str) -> Tuple[str, List[Dict]]:
    """
    既存の main.py に合わせて引数は残す（KB_MODEL_ARN は今回は使わない）。
    """
    hits = retrieve(region, kb_id, question, k=3)

    if not hits:
        return (
            "該当する社内ナレッジが見つかりませんでした。原本（社内ポータル/担当窓口）を確認してください。",
            []
        )

    # 参照（重複は除く）
    citations = []
    seen = set()
    for i, h in enumerate(hits, start=1):
        key = h["source"]
        if key in seen:
            continue
        seen.add(key)
        citations.append({"id": i, "source": h["source"], "uri": h["source_uri"], "score": h["score"]})

    # 生成（Bedrock RuntimeでClaudeを叩く）
    # main.py の MODEL_ID を環境変数で統一しているなら、ここでは固定せず main 側で渡すのが理想。
    # でも main.py を変えたくない場合は、環境変数から読む形にしてもOK。
    import os
    from .prompts import SYSTEM
    model_id = os.getenv("BEDROCK_MODEL_ID", "anthropic.claude-3-5-sonnet-20240620-v1:0")

    answer = generate_with_claude(region, model_id, SYSTEM, question, hits)

    return answer, citations