---
title: "Ansible × Packer × Karpenter で EKS の Golden AMI パイプラインを構築した"
emoji: "🛡️"
type: "tech"
topics: ["AWS", "EKS", "Ansible", "Terraform", "Karpenter"]
published: false
---

## はじめに

EKS のノード管理で「セキュリティ強化済みの AMI を全ノードに強制したい」という要件に直面したことはないでしょうか。

この記事では **Ansible + Packer で CIS Benchmark 適用済みの Golden AMI をビルドし、Karpenter EC2NodeClass に自動適用する**パイプラインを解説します。

GitHub リポジトリ: [eks-golden-node-pipeline](https://github.com/tk-21/eks-golden-node-pipeline)

## アーキテクチャ全体像

```
Ansible Playbook（CIS Benchmark + containerd + EKS準備）
    ↓
Packer → Golden AMI（ap-northeast-1）
    ↓
Terraform → EKS + Karpenter
    ↓
EC2NodeClass（AMI ID 直接指定）→ EKS Node 起動
```

## 1. Ansible でハードニングを自動化

### CIS Benchmark Level 1 の主要設定

CIS Benchmark は「安全なシステム設定のベストプラクティス集」です。主な適用内容：

- 不要なファイルシステムモジュールを無効化（cramfs, udf など）
- SSH ハードニング（root ログイン禁止、強い暗号のみ許可）
- カーネルパラメータの最適化（SYN Cookie、IP スプーフィング対策）
- auditd による特権操作の監査

```yaml
# CIS Benchmark: sysctl 設定例
- name: SYN Cookie 有効化（SYNフラッド対策）
  ansible.posix.sysctl:
    name: net.ipv4.tcp_syncookies
    value: "1"
    sysctl_set: true
```

### EKS ノードに特有の設定

EKS では CIS Benchmark の一部設定が Kubernetes の動作と競合します。例えば `net.ipv4.ip_forward` は EKS ノードで **必ず有効**にする必要があります。

```yaml
# EKSノードに必要なIPフォワード（CIS Benchmarkの例外設定）
- { key: "net.ipv4.ip_forward", value: "1" }
```

## 2. Packer で AMI をビルド

### Immutable AMI 原則

AMI は「一度ビルドしたら変更しない」が原則です。設定変更時は AMI を再ビルドし、Karpenter がノードを順次入れ替えます。

```hcl
# AMI名にタイムスタンプを含めることで、どのビルドかを追跡可能
locals {
  ami_name = "golden-ami-eks-${var.eks_version}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
}
```

### Data Source で最新ベース AMI を動的取得

```hcl
data "amazon-ami" "amazon_linux_2023" {
  filters = {
    name = "al2023-ami-2023.*-kernel-*-arm64"
  }
  most_recent = true
  owners      = ["137112412989"]  # Amazon公式
}
```

## 3. Karpenter で Golden AMI を強制適用

### EC2NodeClass: AMI ID の直接指定

`latest` タグや名前フィルタによる暗黙的な AMI 参照は禁止し、AMI ID を明示的に指定します。

```yaml
spec:
  amiSelectorTerms:
    - id: "ami-xxxxxxxxxx"  # Packer でビルドした Golden AMI ID
```

### NodePool: 7 日ごとにノードを入れ替え

`expireAfter: 168h` を設定することで、Karpenter が 7 日後に古いノードを安全に入れ替えます。これにより最新の Golden AMI が自動的に全ノードに適用されます。

```yaml
spec:
  template:
    spec:
      expireAfter: 168h  # 7日でノード入れ替え → 最新Golden AMI強制適用
```

## 4. GitHub Actions (OIDC) で全自動化

IAM Access Key を一切使わず、OIDC で一時クレデンシャルを取得します。

```yaml
- name: AWS OIDC 認証
  uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-actions-role
    aws-region: ap-northeast-1
```

## まとめ

| 課題 | 解決策 |
|---|---|
| EKS ノードのセキュリティ強化 | Ansible CIS Benchmark ロール |
| 設定の冪等性・追跡可能性 | Packer + Git管理 |
| 全ノードへの AMI 強制適用 | Karpenter EC2NodeClass + expireAfter |
| CI/CD のセキュリティ | GitHub Actions OIDC |

コード全体は GitHub で公開しています：
https://github.com/tk-21/eks-golden-node-pipeline
