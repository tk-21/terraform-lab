# ADR-0007: CI/CDパイプライン設計

## Status

Accepted

## Date

2026-07-23

## Context

Phase 7では、手元で動かしてきたビルド・テスト・デプロイをGitHub Actionsで自動化する。
以下の制約・要件がある。

- IAMアクセスキーの発行禁止(CLAUDE.mdのポリシー)
- 全インフラarm64/Graviton2統一(CLAUDE.mdのポリシー)
- CIはGitHub Actions(無料枠のubuntu-latestランナー = x86_64ホスト)
- Admission Webhookはcert-managerが必要だが、CIのKindにcert-managerを入れるとジョブ時間が増加する
- GPU(NVIDIA/DCGM)がCIランナーに存在しない

## Decision

<!-- この節のみ人間が記述すること (CLAUDE.mdのルール3) -->
<!-- TODO: 実装後に自分の言葉で記載する -->

## Options

### Option A: IAMアクセスキー + x86イメージのみ

- メリット: 設定が簡単
- デメリット: アクセスキーのローテーション管理が発生、アーキ統一方針に反する

### Option B: OIDC + arm64専用ビルド (採用)

- メリット: 短命トークンで漏洩リスク最小、arm64統一でインフラ一貫性
- デメリット: OIDCロールのTerraform設定が必要、ローカルがx86 Macの開発者はDockerイメージをQEMUでビルドできない

### Option C: OIDC + マルチアーキビルド(arm64 + amd64)

- メリット: x86環境でも動作確認できる
- デメリット: CIビルド時間・ECRストレージコストが約2倍、本番環境がarm64のみなのでamd64イメージは実質使われない

## Consequences

### 採用した設計の詳細

**OIDC認証 (terraform/modules/github-oidc/)**

- `aws_iam_openid_connect_provider` でGitHub OIDCエンドポイントを登録
- IAMロールのConditionで `token.actions.githubusercontent.com:sub` を
  `repo:<org>/<repo>:ref:refs/heads/main` と `ref:refs/tags/v*` に限定
  → forkや他ブランチからの意図しないAssumeRoleを防ぐ
- ECRへのpush権限はリポジトリARNを明示して `ecr:GetAuthorizationToken` のみリソース `*` を許容

**arm64専用ビルド (.github/workflows/release.yml)**

- `docker/build-push-action` に `platforms: linux/arm64` のみ指定
- GoのクロスコンパイルはCGO不要なため、QEMUエミュレーションなしに高速ビルドできる
- x86_64ランナー上でarm64イメージをビルドしてECRにpushする

**CI/CDのジョブ分割 (.github/workflows/ci.yml)**

1. `lint` - golangci-lint (PRで高速フィードバック)
2. `unit-test` - envtest (インプロセスのKubernetes API、CRD/RBAC生成含む)
3. `e2e` - Kind上でCR作成→Deployment生成を検証
4. `helm-lint` - Helm Chart構文チェック

**E2EテストのGPU依存部分モック化 (test/e2e/)**

- `BedrockFallback.Enabled: false` → AWS Bedrock APIへの接続なし
- `ScalingMetric.PrometheusURL: ""` → DCGM Exporterへの接続なし
- `SKIP_GPU_TESTS: true` 環境変数 → GPU依存アサーションをスキップ
- 検証対象を「CRD適用 → Operatorの起動 → CR作成 → Deployment生成」に絞る

- Webhookは `--enable-webhooks=false` フラグ(main.goに追加)でCI上では無効化する
  → cert-managerなしでもOperatorを起動できる

**Helm Chart (helm/gpu-inference-operator/)**

- Operator Deployment、ServiceAccount、ClusterRole/Binding、Service(metrics/webhook)を1 Chartで管理
- `webhook.enabled: false` でcert-managerなし環境(Kind/ステージング初期)でも `helm install` できる
- nodeSelector に `kubernetes.io/arch: arm64` を設定してGraviton2ノードにスケジュール

### トレードオフ・リスク

- arm64専用イメージ: x86_64のローカルMacでは `docker run` できない(開発体験の制約)
- Webhookのモック化: バリデーションルールが回避されたCRでもE2Eが通ってしまうリスクがある
  → Webhookのテストはcontrollers/suite_test.goのenvtestで別途カバーしている
- Kindのarm64制約: KindクラスタはCIホスト(x86_64)上で動くためarm64イメージを直接デプロイできない
  → E2E用のOperatorバイナリはamd64でビルドしてCIホスト上で直接実行する

## References

- [GitHub Actions OIDC documentation](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/about-security-hardening-with-openid-connect)
- [docker/build-push-action multiplatform](https://github.com/docker/build-push-action#usage)
- [kubebuilder envtest](https://book.kubebuilder.io/reference/envtest)
- Phase 1-6の実装成果物
