# CLAUDE.md - eks-performance-tuning

## プロジェクト概要
EKS + AWS インフラのパフォーマンスチューニングをポートフォリオ化するプロジェクト。
負荷テスト → ボトルネック特定 → チューニング → 効果測定 のサイクルを実践・記録する。

## ディレクトリ構成
```
eks-performance-tuning/
├── terraform/
│   ├── environments/
│   │   └── dev/           # 検証環境（コスト最小化）
│   └── modules/
│       ├── eks/           # EKSクラスター（Karpenter付き）
│       ├── observability/ # Prometheus/Grafana/X-Ray
│       ├── load-test/     # k6 on Fargate
│       └── sample-app/    # チューニング対象アプリ
├── k8s/
│   ├── karpenter/         # NodePool, EC2NodeClass
│   ├── keda/              # ScaledObject, TriggerAuthentication
│   ├── hpa/               # HorizontalPodAutoscaler
│   ├── vpa/               # VerticalPodAutoscaler
│   └── sample-app/        # Deployment, Service, PodDisruptionBudget
├── load-tests/
│   ├── scenarios/         # k6スクリプト（段階的負荷）
│   └── results/           # ベースライン・チューニング後の結果JSON
├── dashboards/
│   └── grafana/           # ダッシュボードJSON（import用）
├── scripts/
│   ├── run-benchmark.sh   # 負荷テスト実行 + 結果保存
│   └── compare-results.sh # チューニング前後比較レポート生成
├── docs/
│   ├── architecture.md    # Mermaidアーキテクチャ図
│   ├── tuning-results.md  # チューニング結果まとめ（Zenn記事素材）
│   └── adr/               # Architecture Decision Records
└── .github/
    └── workflows/
        ├── tf-plan.yml    # Terraform plan（OIDC認証）
        └── benchmark.yml  # 定期ベンチマーク実行
```

## 命名規則
- Terraformリソース: `ept-{env}-{service}` (eks-performance-tuning)
- K8s Namespace: `perf-tuning`, `observability`, `load-test`
- Grafanaダッシュボード: `EPT - {対象} Overview`

## 禁止パターン
- static AWS access keys（OIDC必須）
- `kubectl apply` の手動実行（ArgoCD or Terraform provider経由）
- `requests` と `limits` の未設定Pod
- `latest` タグのコンテナイメージ

## タグ戦略
```hcl
locals {
  common_tags = {
    Project     = "eks-performance-tuning"
    Environment = var.environment
    ManagedBy   = "terraform"
    Owner       = "takuya"
    Purpose     = "portfolio-performance"
  }
}
```

## コスト上限
- 月次目標: $20以下
- EKS: spot instanceメイン（Karpenter）
- 負荷テスト: 実行時のみFargate起動、終了後削除

## 言語・バージョン
- Terraform: >= 1.7
- Python: 3.12（Lambda使用時）
- Lambda arch: arm64
- K8s: 1.30+

## 設計ポリシー
- チューニング前後は必ず数値で記録（p50/p95/p99レイテンシ、スループット、コスト）
- 改善量は % で表現できる形でresults/に保存
- Zenn記事の素材になるよう、失敗含めて経緯を docs/ に記録