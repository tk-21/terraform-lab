# トラブルシューティングランブック

## Istio Sidecar が Inject されない

### 症状
`kubectl get pods -n mesh-apps` で Pod のコンテナ数が `1/1`（`2/2` にならない）。

### 確認手順

```bash
# Namespace に istio-injection ラベルが付いているか確認
kubectl get ns mesh-apps --show-labels

# ラベルがない場合は付与
kubectl label namespace mesh-apps istio-injection=enabled

# Pod を再作成して sidecar を inject させる
kubectl rollout restart deployment -n mesh-apps
```

### 原因
- Namespace に `istio-injection: enabled` ラベルが付いていない
- `istiod` が Running でない（`kubectl get pods -n istio-system` で確認）
- Pod に `sidecar.istio.io/inject: "false"` アノテーションが付いている

---

## mTLS 接続失敗

### 症状
サービス間通信で `Connection reset` や `TLS handshake error` が発生する。

### デバッグコマンド

```bash
# Envoy プロキシの設定同期状態を確認
istioctl proxy-status

# 設定の問題点を自動検出
istioctl analyze -n mesh-apps

# 特定 Pod の Envoy 設定を確認
istioctl proxy-config cluster <pod-name> -n mesh-apps

# mTLS チェック（STRICT/PERMISSIVE/DISABLE を確認）
istioctl authn tls-check frontend.mesh-apps.svc.cluster.local

# Envoy アクセスログを確認
kubectl logs <pod-name> -c istio-proxy -n mesh-apps | tail -50
```

### よくある原因と対処

| 原因 | 対処 |
|---|---|
| PeerAuthentication が STRICT だが DestinationRule の tls.mode が未設定 | `destination-rule.yaml` に `tls.mode: ISTIO_MUTUAL` を追加 |
| Sidecar が inject されていない Pod への通信 | 該当 Namespace に `istio-injection=enabled` を付与して Pod 再作成 |
| 古い Envoy 設定がキャッシュされている | `kubectl rollout restart deployment -n mesh-apps` |

---

## カナリアが正しく動作しない

### 症状
`curl` を繰り返しても常に v1 または v2 のみレスポンスが返る。

### 確認手順

```bash
# VirtualService の設定確認
kubectl get vs frontend -n mesh-apps -o yaml

# DestinationRule の subset ラベルと Pod ラベルの一致確認
kubectl get pods -n mesh-apps --show-labels | grep frontend

# Envoy のルート設定を確認
istioctl proxy-config routes <frontend-pod-name> -n mesh-apps

# Istio 設定の問題点を検出
istioctl analyze -n mesh-apps
```

### よくある原因

- VirtualService の `hosts` に Ingress Gateway 経由のホストが含まれていない
- DestinationRule の `subsets[].labels` と Pod の `version` ラベルが一致していない
- VirtualService と DestinationRule が異なる Namespace に存在する

---

## サーキットブレーカーの動作確認

### 動作確認手順

```bash
# テスト用設定（閾値を 1 に下げたもの）を適用
kubectl apply -f k8s/istio/traffic-policy/circuit-breaker.yaml

# fortio で負荷をかける（事前に fortio Pod をデプロイ）
kubectl run fortio \
  --image=fortio/fortio \
  --restart=Never \
  -n mesh-apps \
  -- load -c 3 -qps 10 -n 50 http://frontend/

# メトリクスでエジェクション数を確認
kubectl exec -n mesh-apps <any-pod> -c istio-proxy -- \
  pilot_agent request GET stats | grep outlier

# 確認後は本番設定に戻す
kubectl apply -f k8s/istio/destination-rule.yaml
kubectl delete pod fortio -n mesh-apps
```

---

## EKS ノードが NotReady

### 確認手順

```bash
# ノード状態の詳細確認
kubectl describe node <node-name>

# ノード上のシステム Pod 確認
kubectl get pods -n kube-system -o wide | grep <node-name>

# aws-node（VPC CNI）の状態確認
kubectl get pods -n kube-system | grep aws-node

# EC2 インスタンスのシステムログ確認（AWS CLI）
aws ec2 get-console-output --instance-id <instance-id> --region ap-northeast-1
```

### よくある原因と対処

| 原因 | 対処 |
|---|---|
| ディスク使用率 100% | EBS ボリュームを拡張、または不要なイメージを削除 |
| メモリ不足（OOM） | ノードサイズのアップスケール、または Pod のリソースリミット見直し |
| VPC CNI の IP アドレス枯渇 | サブネットの CIDR 拡張、または ENI プリフィックス割り当ての有効化 |
| EC2 インスタンスのハードウェア障害 | ノードグループの更新（インスタンスを置換）|

```bash
# ノードを安全にドレインしてから削除
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data
kubectl delete node <node-name>
# Auto Scaling Group が自動で新しいノードを起動する
```
