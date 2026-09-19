# STAR形式 技術面接想定問答

> **記載方針**
> - 実測値が取得済みの項目は実数を記載
> - 実EKSで未計測の項目は「TBD(実測値)」と明記し、設計根拠のある数値は推計として区別
> - 四部構成: 課題の定量化 → 技術選定の理由 → 効果・インパクト → 何が難しかったか

---

## Q1. KEDAではなく自作Operatorにした理由と効果を教えてください

### 課題の定量化

KEDAのデフォルトポーリング間隔は15秒、CloudWatch Alarmの評価間隔は最短60秒。
LLMのリクエストキューは数秒でバースト・消滅するため、15秒のポーリングでは
「スケールアウトが必要なタイミングとGPUが増える時刻のずれ」が最大15秒生じる。
SQSキュー深度が0→50件に変化した場合、KEDAは最大15秒後にスケールを検知するが、
GPUノードのコールドスタート(3〜5分)が別途加算されるため、合計の推論開始まで
3分15秒〜5分15秒かかる計算になる。

### 技術選定の理由

ポーリング間隔を5秒に短縮できるカスタムコントローラーを自作することで、
スケール検知のレイテンシを最大15秒→5秒に短縮できると判断した。
また、KEDAは「スケール判定」だけを担うが、自作するとことで
フォールバック判定・自己修復・Chatwork通知を同一reconcileループで処理でき、
状態遷移(Running→Fallback→Running)が単一のCRDステータスに集約されるため
オブザーバビリティが向上する。

KEDAを使い続けた場合の代替案:
- ポーリング間隔短縮: KEDAのpollingIntervalを5秒に設定すれば同等のレイテンシは実現できる
- ただしフォールバックロジックはKEDAの外で別途実装が必要になる
- 自作の「学習目的」という文脈では、Operatorパターンの理解のため自作を選択した

### 効果・インパクト

| 指標 | KEDA(15s polling) | 自作(5s polling) |
|---|---|---|
| スケール検知レイテンシ | 最大15秒 | 最大5秒 |
| スケール検知レイテンシ(実測) | TBD | TBD |
| 状態管理の集約 | 複数ツール分散 | CRD単一ステータス |
| フォールバック統合 | 別途実装必要 | reconcileループ内で完結 |

### 何が難しかったか

「ヒステリシスの設計」が最も難しかった。単純な閾値比較でスケールアウト/ダウンを
実装すると、キュー深度が目標値付近でブレる度にフラッピングが発生した。
`scaleDownThresholdRatio=0.7`(スケールアウト閾値の70%を下回るまでスケールダウンしない)
という非対称閾値を設けることで解消したが、この比率の根拠を定量的に示すためのデータ取得
(何秒間隔でキュー深度を観測するか、何回連続で閾値を下回ったらダウンさせるか)に時間がかかった。

---

## Q2. GPUノードのコールドスタート問題にどう対処しましたか

### 課題の定量化

g5g.xlarge(arm64, NVIDIA T4G)のコールドスタートは参照プロジェクト実績で3〜5分。
内訳:
- NodeClaim承認: 約10〜30秒(Karpenter→EC2 API)
- EC2インスタンス起動: 約60〜120秒
- Kubernetes Nodeの登録・Ready: 約30〜60秒
- GPUドライバーロード・vLLMモデルロード: 約60〜120秒

この間、ユーザーのリクエストは処理不能か高レイテンシになる。

### 技術選定の理由

Bedrockへの自動フォールバックを選択。タイムアウト閾値は90秒に設定した。

閾値90秒の根拠(設計時の計算):
- GPUコールドスタート中のコスト: 約4分 × $0.0028/分(Spot中央値) = $0.0112
- Bedrock Claude Haiku 1リクエストのコスト: $0.000448(入力512+出力256 tokens想定)
- BEP: $0.0112 ÷ $0.000448 ≈ 25リクエスト
→ コールドスタート4分間に25件以上のリクエストがある場合、Bedrockフォールバックが
  コスト中立かコスト削減になる

90秒を選んだ理由: コールドスタート成功の中央値が3〜5分であることを踏まえ、
90秒以内に起動が完了するケースは例外的(Spot起動バースト時の稀なケース)と判断した。
実EKSでの計測後に根拠を実測値で上書き予定(TBD)。

### 効果・インパクト

| 指標 | フォールバックなし | フォールバックあり |
|---|---|---|
| コールドスタート中のユーザー体験 | タイムアウト/エラー | Bedrockで処理継続 |
| レイテンシ(コールドスタート中) | 3〜5分または失敗 | Bedrock応答時間(TBD) |
| コスト(BEP: 25 req超の場合) | GPUコスト同等 | コスト削減 |
| activeBackend可視性 | なし | CRD statusで追跡可能 |

### 何が難しかったか

フォールバックからGPUへの「切り戻し判定」が難しかった。
単純に「DeploymentがReadyになったらGPUに戻す」と実装したが、
GPU復帰直後のvLLMはKV-cacheが空でウォームアップ中のため
レイテンシが一時的にBedrockより悪くなる。
この「偽の劣化」をOperatorが検知して再度Bedrockに落とすループが発生しないよう、
復帰後の一定時間はスケーリング判定を抑制するクールダウンを入れる必要があった。

---

## Q3. 自己修復ロジックで最も難しかった設計判断は何ですか

### 課題の定量化

本番LLMサービスでのOOMKilledは致命的: 再起動するたびにモデルロード(60〜120秒)が
発生するため、CrashLoopBackOffになると平均的な停止時間(MTTR)が数分単位になる。
Kubernetes標準の挙動はバックオフ(10s→20s→40s...最大300s)で再起動するため、
停止が長引くほどMTTRが悪化する。

### 技術選定の理由

OOMKillに対しては「メモリlimitを25%増やしてrolling updateで再起動」を選択した。
理由: vLLMのメモリ使用量は確率的(プロンプト長・バッチサイズに依存)なため、
固定値への増加では不十分で、現在の使用量に対して相対的に余裕を持たせる設計が妥当と判断。
上限はNode allocatable memoryの80%に制限してNode圧迫を防ぐ。

CrashLoopBackOffに対しては「maxRestartAttempts=3」で自動修復を停止してDegradedに落とす
判断をした。理由: 根本原因がモデルバグ・環境変数ミスの場合は修復を繰り返すと
コスト暴走・本当の障害の隠蔽が起きるため。

### 効果・インパクト

| 指標 | 修復なし(標準K8s) | 自作Operator |
|---|---|---|
| OOMKilled後の対応 | 同一limitで再起動を繰り返す | limitを25%増量してrolling update |
| MTTR(OOMKilled 1回目) | バックオフ含め2〜5分 | 約60〜90秒(rolling update時間) |
| CrashLoop継続の有無 | 続く(バックオフ間隔は延びる) | maxAttempts到達でDegradedに遷移 |
| 人間への通知 | なし(PodがRestartingのまま) | Chatwork通知 + Degraded status |

### 何が難しかったか

「Podのrestartが自作Operatorによるrolling updateか、Kubernetesのバックオフによる再起動か」
を区別することが難しかった。両者ともPodの`restartCount`が増加するため、
単純に`restartCount`を監視すると自分のrolling updateを「失敗」と誤検知する。

解決策: AISのCRDに`status.restartCount`を独自に持ち、Operatorが明示的にIncrement
するタイミング(OOMKilled検知→bump実施後)のみカウントアップする設計にした。
KubernetesネイティブのPod restartCountとは別管理にすることで誤検知を排除した。

---

## Q4. Admission Webhookで検証した項目と、誤検知が出たケースを教えてください

### 課題の定量化

Webhookを入れる前の手動テストで、以下の設定ミスが複数回発生した:
- `gpuNodePoolRef`を指定しているのに`nvidia.com/gpu`limitがない → Podがスケジュール失敗
- `scalingMetric.type=queueDepth`なのに`queueName`未設定 → reconcileがpanicに近い状態

これらは全てAdmission時点で弾けるエラーで、reconcileループで発見してもStatusへの反映が遅れる。

### 技術選定の理由

ValidatingWebhookを選択。MutatingWebhookはdefault値の補完(minReplicas=0のdefault設定等)に使い、
ビジネスロジック的な整合性チェック(GPU limit必須、queueName必須等)はValidatingで実施する
責務分担にした。

### 効果・インパクト

| バリデーション項目 | Webhook前の影響 | Webhook後 |
|---|---|---|
| GPU limit未設定 | Podがscheduled失敗 | apply時点でエラー |
| queueName未設定 | reconcile内でnilポインタ | apply時点でエラー |
| maxReplicas < minReplicas | Deploymentが誤った状態 | apply時点でエラー |

### 何が難しかったか

「既存CRDへのWebhook追加」時の対応が難しかった。Webhookを後から追加すると、
既存の(webhookなしで作成された)CRDリソースが`kubectl edit`された際に
新しいバリデーションに引っかかることがある。
これを回避するため、ValidatingWebhookのfailurePolicyを一時的に`Ignore`にして
段階的にロールアウトし、全既存リソースを修正してから`Fail`に変更する手順が必要だった。

---

## Q5. GitHub ActionsでのCI/CDでarm64マルチアーキビルドを選んだ理由を教えてください

### 課題の定量化

EKSノードをarm64(Graviton2/g5g)に統一している制約から、
Operatorイメージもarm64でビルドする必要がある。
一方、GitHub ActionsのデフォルトRunnerはx86_64(ubuntu-latest)であり、
QEMUエミュレーション経由のarm64ビルドは遅い(参考: Go 1.22のクロスコンパイルで約5〜8分)。

### 技術選定の理由

`docker buildx`のマルチプラットフォームビルドを採用し、`--platform=linux/arm64,linux/amd64`で
一つのイメージマニフェストに両アーキビルドを格納する方針を取った。

代替案と却下理由:
- arm64 self-hosted Runner: 維持コストが高い。今回は学習目的のプロジェクトのため不採用
- arm64専用ビルドのみ: ローカル(M1 Mac等)での開発体験が悪化する
- QEMU + ネイティブarm64クロスコンパイル: Goはクロスコンパイルが得意なため
  `GOARCH=arm64 GOOS=linux go build`だけでバイナリは作れるが、
  Dockerイメージ内のC拡張(vLLM等)はQEMU必須になる可能性があるため両プラット対応を維持

### 効果・インパクト

| 指標 | 値 |
|---|---|
| イメージ対応アーキテクチャ | arm64 + amd64 |
| CI実行時間(ビルドジョブ) | TBD(計測予定) |
| OIDC認証 | IAMアクセスキー0件 |
| ECRへのpush | ロール: `gpu-inference-operator-github-actions-role` |

### 何が難しかったか

OIDC認証の設定で`aud`クレームの扱いに詰まった。
GitHub ActionsのOIDCトークンの`aud`は`sts.amazonaws.com`が既定だが、
TerraformでIAM Trust Policyを書く際に`StringEquals`で`token.actions.githubusercontent.com:aud`を
正確に指定しないと`AccessDenied`が出る。
エラーメッセージが「認証情報が無効」という汎用メッセージのため、
`aud`が問題だと特定するまでにCloudTrailのログを読み込む必要があった。
