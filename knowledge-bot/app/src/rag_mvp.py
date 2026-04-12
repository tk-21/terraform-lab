import re
from typing import Dict, List


def _tokenize(text: str) -> List[str]:
    normalized = text.lower()
    ascii_tokens = re.findall(r"[a-z0-9_]+", normalized)
    japanese_runs = re.findall(r"[\u3040-\u30ff\u3400-\u9fff]+", normalized)

    tokens = set(ascii_tokens)
    for run in japanese_runs:
        if len(run) == 1:
            tokens.add(run)
            continue

        tokens.add(run)
        for size in (2, 3):
            if len(run) >= size:
                tokens.update(run[i : i + size] for i in range(len(run) - size + 1))

    return sorted(tokens)


def simple_retrieve(chunks: List[Dict], query: str, k: int = 4) -> List[Dict]:
    # MVP向けの簡易検索。英数字トークンと日本語n-gramの部分一致で上位だけ返す。
    query_tokens = _tokenize(query)
    scored = []

    for chunk in chunks:
        haystack = " ".join(
            [
                chunk.get("source", ""),
                chunk.get("section", ""),
                chunk.get("text", ""),
            ]
        ).lower()
        score = sum(1 for token in query_tokens if token and token in haystack)
        if score > 0:
            scored.append((score, chunk))

    scored.sort(key=lambda item: item[0], reverse=True)
    return [chunk for _, chunk in scored[:k]]
