-- ブロックされたリクエスト数 TOP 20 の送信元 IP
-- パーティションフィルタ (year/month) を必ず指定してスキャンコストを抑えること

SELECT
  httpRequest.clientIp                   AS client_ip,
  httpRequest.country                    AS country,
  COUNT(*)                               AS blocked_count,
  MAX(from_unixtime(timestamp / 1000))   AS last_seen
FROM waf_logs
WHERE action = 'BLOCK'
  AND year  = '2025'
  AND month = '01'
GROUP BY 1, 2
ORDER BY blocked_count DESC
LIMIT 20;
