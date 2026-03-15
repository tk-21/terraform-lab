import re
from typing import List, Dict

def simple_retrieve(chunks: List[Dict], query: str, k: int = 4) -> List[Dict]:
  q = re.findall(r"\w+", query.lower())
  scored = []
  for c in chunks:
    text = c["text"].lower()
    score = sum(1 for w in q if w in text)
    if score > 0:
      scored.append((score, c))
  scored.sort(key=lambda x: x[0], reverse=True)
  return [c for _, c in scored[:k]]