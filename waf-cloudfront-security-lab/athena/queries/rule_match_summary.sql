-- ルールごとのマッチ数集計
-- どのルールが最も多くヒットしているか確認する
-- count モードで運用中のルールは action = 'COUNT' で現れる

SELECT
  terminatingRuleId   AS rule_id,
  action,
  COUNT(*)            AS match_count
FROM waf_logs
WHERE year  = '2025'
  AND month = '01'
GROUP BY 1, 2
ORDER BY match_count DESC;
