# ADR 001: Golden AMI 戦略

## ステータス

承認済み

## コンテキスト

EKS ノードの AMI 管理方法として以下の選択肢がある：

1. **EKS 最適化 AMI（AWS公式）をそのまま使用**
2. **Golden AMI を自前でビルド**
3. **Bottlerocket OS を使用**

## 決定

Golden AMI を Ansible + Packer で自前ビルドする（選択肢 2）。

## 理由

- **セキュリティ要件**: CIS Benchmark Level 1 を全ノードに強制適用したい
- **冪等性**: Ansible ロールにより、AMI の内容を宣言的に管理できる
- **監査**: どのソフトウェアがインストールされているかコードで追跡可能
- **ポートフォリオ差別化**: Ansible × Packer × Karpenter の統合は事例が少なく高付加価値

## トレードオフ

- AMI ビルドのパイプライン運用コストが発生する
- EKS バージョンアップ時に AMI 再ビルドが必要

## 代替案の却下理由

- **Bottlerocket**: カスタマイズの自由度が低く、Ansible で設定を管理できない
- **AWS公式AMIそのまま**: CIS Benchmark 非準拠、セキュリティ設定の追跡が困難
