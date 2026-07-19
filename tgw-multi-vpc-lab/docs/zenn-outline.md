# Zenn記事アウトライン

## タイトル案
「Transit Gateway × Terraform で実装するHub-and-Spoke VPC設計 ─ SAPの知識を手で動かす」

## 対象読者
- AWSのネットワーク設計を実務レベルで理解したいインフラエンジニア
- SAP-C02の知識をコードに落とし込みたい人

## 記事構成

### 1. はじめに（背景）
- SAP試験でTGWを知識として理解していても、実装経験がないと面接で詰まる
- このハンズオンで「設計判断の言語化」まで行うことを目指す

### 2. 設計する構成の概要
- Hub-and-Spoke構成のMermaid図
- 通信ポリシーの表

### 3. TGWルートテーブルの核心
- AssociationとPropagationの違い（図解）
- 2テーブル設計でSpoke間通信を遮断する仕組み

### 4. Terraformでの実装
- モジュール構成の解説
- for_eachを使った伝播先の管理

### 5. 疎通確認
- SSM Session Managerでの確認方法
- 期待通りに遮断されていることの確認

### 6. 設計判断のまとめ
- なぜVPC PeeringでなくTGWか
- NATGWなしでどう運用するか

### 7. おわりに
- GitHub リポジトリへのリンク
