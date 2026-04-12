# EKS / Ingress トラブルシュート

対象: `knowledgebot` の Service / Ingress / ALB  
想定読者: EKS 運用担当者

## Ingress の URL を開いても表示されない

### 原因候補

- `k8s/base/ingress.yaml` が `alb.ingress.kubernetes.io/scheme: internal` になっている
- `aws-load-balancer-controller` が起動していない
- Pod / Service は正常だが、ALB が VPC 内向けで外部から見えない

### 確認コマンド

```bash
kubectl -n knowledgebot get ingress
kubectl -n knowledgebot describe ingress knowledgebot
kubectl -n kube-system get pods | grep aws-load-balancer-controller
kubectl -n knowledgebot get deploy,svc,pods
```

### 対処

- internal ALB の場合は、VPC 内または VPN 接続下からアクセスする
- 運用確認は `kubectl -n knowledgebot port-forward svc/knowledgebot 8080:80` で代替できる
- `http://localhost:8080/healthz` でアプリ疎通を確認する

## Ingress はあるが ADDRESS が空のまま

### 原因候補

- Load Balancer Controller の権限不足
- ServiceAccount の IRSA 不整合
- Subnet タグや VPC 設定不足

### 確認ポイント

- `aws-load-balancer-controller` のログ
- `ingress` のイベント
- `kubectl -n kube-system describe sa aws-load-balancer-controller`

## 本番運用の考え方

- 一般ユーザー向けの本番導線は `port-forward` ではない
- 社内向け運用なら `internal` ALB + VPN + 社内 DNS が基本
- 外部公開したい場合は `internet-facing` へ変更し、認証方式も再設計する
