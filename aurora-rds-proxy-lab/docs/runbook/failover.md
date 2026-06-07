# Aurora フェイルオーバー 検証結果 & Runbook

## 環境

| 項目 | 値 |
|------|-----|
| Aurora Serverless v2 | Writer (ap-northeast-1a) + Reader (ap-northeast-1c) |
| RDS Proxy | arpl-rds-proxy (IAM 認証, TLS 必須) |
| アプリ | ECS Fargate (FARGATE_SPOT, arm64) |
| 計測方法 | ALB `/health` エンドポイントに 2 秒間隔でポーリング |

---

## 測定結果

| 指標 | 計測値 |
|------|--------|
| フェイルオーバー開始〜完了 | XX 秒 |
| アプリへのエラー数 | X 件 / Y 件中 |
| エラー率 | X.X% |
| フェイルオーバー後のエンドポイント変更 | 不要（Proxy が吸収） |
| Writer/Reader 役割の切替確認 | AZ が入れ替わっていることを確認 |

> ※ 実測後に数値を記入すること

---

## RDS Proxy なしの場合（推定）

- Aurora クラスターエンドポイントが Writer の IP を返すため、フェイルオーバー後に DNS TTL（5 秒）+ アプリの再接続待ちで **合計 30〜60 秒程度のエラー期間**が発生する
- コネクションプールがリセットされ、新 Writer への再接続スパイクで一時的な接続失敗が増加する
- アプリ側で retry ロジックを実装しても、接続先 IP が変わる間はエラーが継続する

---

## 考察

<!-- 以下は自分の言葉で記述すること。AI生成テキストのコピーペースト禁止 -->

RDS Proxy がフェイルオーバーを透過できた理由：

1. **エンドポイントの固定**: アプリは常に Proxy のエンドポイントに接続しており、Aurora の Writer/Reader 切替はアプリから見えない
2. **接続プールの維持**: Proxy が内部で Aurora との接続を管理しているため、フェイルオーバー中も既存の Proxy→アプリ間の接続は維持される
3. **新 Writer への自動再接続**: Proxy が新 Writer を検出して接続を切り替えるため、アプリ側のコード変更は不要

---

## フェイルオーバー実行手順

```bash
# 1. テストスクリプトで自動実行（推奨）
bash scripts/failover-test.sh

# 2. 手動実行の場合
aws rds failover-db-cluster \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1

# フェイルオーバー完了を待機
aws rds wait db-cluster-available \
  --db-cluster-identifier arpl-aurora-cluster \
  --region ap-northeast-1

# Writer/Reader の役割確認
aws rds describe-db-instances \
  --filters "Name=db-cluster-id,Values=arpl-aurora-cluster" \
  --query 'DBInstances[*].{ID:DBInstanceIdentifier,AZ:AvailabilityZone,Status:DBInstanceStatus}' \
  --output table
```

---

## 面接での説明ポイント

**Q: フェイルオーバー時に RDS Proxy がどう振る舞うか？**

RDS Proxy はアプリと Aurora の間に立つため、アプリから見たエンドポイントは変わらない。
Proxy 自身が Aurora の新 Writer を検出して内部接続を切り替えるので、アプリ側は再接続不要。
計測では〇〇秒のフェイルオーバー中にエラー率 X% を達成できた。
