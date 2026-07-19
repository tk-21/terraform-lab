-- 国別リクエスト数とブロック率
-- block_rate_pct が高い国は地理制限 (Lambda@Edge) の対象候補

SELECT
  httpRequest.country                                                      AS country,
  COUNT(*)                                                                 AS total_requests,
  SUM(CASE WHEN action = 'BLOCK' THEN 1 ELSE 0 END)                       AS blocked_count,
  ROUND(
    100.0 * SUM(CASE WHEN action = 'BLOCK' THEN 1 ELSE 0 END) / COUNT(*), 2
  )                                                                        AS block_rate_pct
FROM waf_logs
WHERE year  = '2025'
  AND month = '01'
GROUP BY 1
ORDER BY total_requests DESC;
