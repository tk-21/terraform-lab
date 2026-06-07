# Secrets Manager ローテーション検証 Runbook

## 概要

Aurora の appuser パスワードを Secrets Manager で 7 日ごとに自動ローテーションする構成を、
ゼロダウンタイムで動作することを証明するための手順と結果を記録する。

---

## ローテーションの仕組み（4 ステップ）

```
createSecret  → 新パスワード生成 (AWSPENDING バージョン作成)
setSecret     → Aurora に ALTER USER appuser PASSWORD '新パスワード' を実行
testSecret    → 新パスワードで DB 接続テスト
finishSecret  → AWSPENDING を AWSCURRENT に昇格、旧バージョンを AWSPREVIOUS に降格
```

**接続断が起きない理由**: `setSecret` 〜 `finishSecret` の間、RDS Proxy は
`AWSCURRENT`（旧）と `AWSPENDING`（新）の両パスワードを一時的に受け入れる。
そのため既存の接続は旧パスワードのまま継続でき、新しい接続は新パスワードで確立される。

---

## 測定結果

| 指標 | 計測値 |
|------|--------|
| ローテーション所要時間 | XX 秒 |
| 監視期間中の総リクエスト数 | X 件 |
| エラー数 | 0 件 |
| 結論 | 接続断なし |

> ※ 実測後に数値を記入すること

---

## 検証実行手順

```bash
# ALB 経由でアプリに連続リクエストを送りながらローテーションを実施
bash scripts/verify-rotation.sh

# ローテーション状態の確認
aws secretsmanager describe-secret \
  --secret-id arpl/db/appuser \
  --query '{RotationStatus:RotationStatus,LastRotatedDate:LastRotatedDate}' \
  --output table \
  --region ap-northeast-1

# 手動でローテーションをトリガーする場合
aws secretsmanager rotate-secret \
  --secret-id arpl/db/appuser \
  --rotate-immediately \
  --region ap-northeast-1
```

---

## トラブルシューティング

### ローテーション Lambda が失敗する場合

```bash
# Lambda のログを確認
aws logs tail /aws/lambda/arpl-rotation-lambda --since 10m --region ap-northeast-1

# よくある原因:
# - Lambda が VPC Endpoint 経由で Secrets Manager に到達できない
# - Lambda の IAM ロールに secretsmanager:GetSecretValue が不足
# - Aurora のセキュリティグループが Lambda からのポート 5432 を拒否している
```

### ローテーション後にアプリが DB に繋がらない場合

```bash
# ECS タスクのログを確認
aws logs tail /ecs/arpl-app --since 5m --region ap-northeast-1

# よくある原因:
# - アプリがシークレットをキャッシュしていて古いパスワードを使い続けている
# - RDS Proxy の IAM ロールに secretsmanager:GetSecretValue が不足
```
