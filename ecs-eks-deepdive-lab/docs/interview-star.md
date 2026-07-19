# STAR形式 面接想定Q&A: ECS/EKS Deepdive Lab

---

## Q1. ECSとEKSの選定経験を教えてください

**Situation（背景）**:
同一のジョブワークロード（FastAPI API + SQSバックグラウンドWorker）を
ECS FargateとEKS Karpenterの両環境に実際にデプロイし、定量比較を実施した。

**Task（課題）**:
「ECSとEKSどちらを選ぶべきか」という問いに対して、感覚論ではなく
実測データに基づいた回答ができるエンジニアになることが目標だった。

**Action（行動）**:
- 200ジョブ / 並列20リクエストのロードテストを両環境で実施
- CloudWatch Container Insights + KEDA メトリクスでスケーリング挙動を計測
- スケールアウト開始時刻をストップウォッチで記録

**Result（結果）**:
<!-- 実測値を記入 -->
- ECS: p95=___ms、スケールアウト開始まで約___秒（CloudWatch Alarm 60s評価が律速）
- EKS: p95=___ms、スケールアウト開始まで約___秒（KEDA 15sポーリングが高速）
- KEDA minReplicaCount=0 により、静穏時のWorker EC2コストをゼロにできることを確認

**面接での差分化ポイント**:
「ECSはシンプルだがスケーリングが遅い」という定性論ではなく、
「ECSのトリガーはCloudWatch Alarm評価周期60秒、KEDAは15秒ポーリングで
4倍の頻度差がある」と数値で語れること。

---

## Q2. Karpenter と Cluster Autoscaler の違いを説明してください

**Situation**: EKS環境でコスト最適化のためのノード自動スケーリングを実装した。

**Task**: Karpenterを選定した理由を設計根拠込みで説明する。

**Action**:
Karpenterを選んだ主な理由3点:
1. **ノードグループ不要**: CA(Cluster Autoscaler)はNode Groupのmin/maxで制約されるが、
   KarpenterはNodePool定義内で複数インスタンスタイプを列挙でき、
   その場の最安値SpotインスタンスをBinpackで選択する
2. **プロビジョニング速度**: CA≈3-5分 vs Karpenter≈30-60秒（実測）。
   CA経由のASGスケールアップはAWS API待ちが長い
3. **consolidation**: WhenUnderutilized でアイドルノードを自動削除、
   Disruption Budget(20%)でダウンタイムを制御

**Result**: Spot + arm64(c6g/m6g/r6g) 組み合わせでコンピュートコストを
オンデマンドx86比で約___%削減（実測値）。

---

## Q3. Pod Identity と OIDC IRSA の違いを説明してください

**Situation**: EKS上のワークロード（KEDA, LBC, APIサーバー等）に
最小権限のIAMロールを付与する必要があった。

**Task**: 新規プロジェクトでPod IdentityとIRSAどちらを使うか判断した。

**Action**:
Pod Identity（2023年11月 GA）を選択した理由:
- IRSA: ServiceAccount annotationにrole ARNを直接書く →
  Terraformのmodule分離が難しく、role ARNがk8s側に漏出する
- Pod Identity: `aws_eks_pod_identity_association` リソースでAWS側が
  ServiceAccount↔IAMロールのマッピングを管理。
  k8s manifestにIAM情報が一切不要
- Trust Policy: `pods.eks.amazonaws.com` という新しいサービスプリンシパルを使用。
  `sts:TagSession` アクションが必須（忘れると403になる）

**Result**: Terraform側でIAM + Pod Identity Associationを管理し、
k8s manifestはIAM非依存に保てた。後からロールを変更する際の
diff範囲がTerraformのみになりレビューしやすい。

---

## Q4. Fargate Spot でのグレースフルシャットダウン実装を教えてください

**Situation**: コスト削減のためWorkerをFargate Spotで動かしていた。

**Task**: Spot中断（2分前通知 → SIGTERM）時にSQSメッセージを処理中断せず
安全にシャットダウンする仕組みが必要だった。

**Action**:
ECSタスク定義で2点設定:
1. `stopTimeout=30`: SIGTERM受信からSIGKILLまでの猶予を30秒確保
2. `initProcessEnabled=true`: PID1をtini（init process）にし、
   シグナルが正しく子プロセスへ伝播するようにした

Pythonコード側:
```python
import signal

def sigterm_handler(signum, frame):
    """SIGTERM受信時: 現在処理中のメッセージを完了してから終了"""
    global shutdown_requested
    shutdown_requested = True  # whileループを抜ける
    # SQS visibility timeout内（300秒）に完了できなければDLQへ

signal.signal(signal.SIGTERM, sigterm_handler)
```

**Result**: Spot中断発生時も処理中メッセージをDLQに落とさずに完了できることを
ECS Execでログ確認してテスト済み。
`stopTimeout` を30秒にした根拠: ジョブの平均処理時間が約___秒のため、
30秒あれば99%のジョブが完了できる（実測）。
