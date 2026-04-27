# ADR-002: VPAをAdvisoryモード（UpdateMode: Off）に限定する

**Date:** 2026-04-27  
**Status:** Accepted

## Context

VPA（Vertical Pod Autoscaler）のAutoモードを試験的に適用したところ、VPAによるPodの自動再起動がサービス断を引き起こした。特に負荷テスト中にVPAがresourcesを更新しようとすると、Podがevictされて一時的に全レプリカが0になるケースが発生した。

## Decision

VPAのUpdateModeを`Off`に設定し、推奨値の表示のみに使用する。実際のrequests/limitsの変更は、VPAの推奨値を参考にして手動で`deployment.yaml`を更新する。

```yaml
updatePolicy:
  updateMode: "Off"
```

## Consequences

**メリット:**
- 負荷テスト中のPod自動再起動によるサービス断が発生しない
- VPAの推奨値を確認してから意図的に変更するため、変更の根拠が明確になる
- チューニング記録（tuning-results.md）に「VPA推奨値→採用値」の対応を残せる

**トレードオフ:**
- リソース最適化が自動化されないため、定期的な手動レビューが必要
- 急激な負荷増加時にVPAが自動対応できず、HPA/KEDAに依存することになる

## 実績

VPAのAdvisoryモードで確認した推奨値:
- requests.cpu: 100m → 推奨250m（採用: 250m）
- limits.cpu: 200m → 推奨500m（採用: 500m）
- requests.memory: 64Mi → 推奨256Mi（採用: 256Mi）
- limits.memory: 128Mi → 推奨512Mi（採用: 512Mi）

この推奨値を採用した結果、CPU Throttling率が87%→4%に削減された。
