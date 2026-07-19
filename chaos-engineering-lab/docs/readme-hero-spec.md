# README Hero Spec

README 用のヒーロー画像を作る前に参照する、このプロジェクト専用の指定ファイル。

## Basic
- Project name: `chaos-engineering-lab`
- Audience: 採用担当者、技術レビュー担当者、AWS / Terraform 学習者
- Primary language: Japanese
- Output path: `docs/readme-hero.png`

## Messaging
- One-line summary: AWS FIS と Terraform を使って CPU ストレス実験と ASG スケールアウトを学ぶハンズオン基盤
- What should be understood at a glance: 何を検証するプロジェクトか、どの AWS サービスが連携するか、実験から観測までの流れ
- Top 3 selling points:
  - FIS 実験テンプレートを含む構成を Terraform で一貫管理している
  - SSM による SSH 不要の CPU ストレス注入と、安全な実験設計を両立している
  - CloudWatch と Target Tracking による検知からスケールアウト確認までをハンズオンで追える

## Visual Direction
- Tone: モダン、実務的、信頼感がありつつ学習用途として親しみやすい
- Color hints: ネイビー基調、アクセントにオレンジとティール、背景は明るめ
- Preferred layout: 横長、左にタイトルと要約、中央から右にアーキテクチャとフロー、下部に短いステップ
- Avoid: 縦長ポスター、文字の詰め込み、スクリーンショット依存、過度に派手な演出

## Content Inputs
- Key services / technologies:
  - AWS FIS
  - Terraform
  - EC2 Auto Scaling / ALB / CloudWatch / SSM
- Flow to visualize:
  1. Terraform で VPC、ALB、ASG、IAM、FIS の実験基盤を構築する
  2. `run_experiment.sh` から FIS 実験を起動し、ASG 内の一部インスタンスへ CPU ストレスを注入する
  3. CloudWatch が CPU 利用率を監視し、Target Tracking がスケールアウトを判断する
  4. `check_scaling.sh` やログで実験結果とインスタンス増減を確認する
- Labels or phrases to include:
  - `影響範囲 50%`
  - `CPU > 90% × 10分で停止`
  - `SSH 不要`
  - `Target Tracking CPU 70%`

## README Placement
- Insert position: タイトル、概要、バッジの直下
- Markdown or HTML: Markdown
- Existing image to replace: `docs/readme-hero.png`

## Notes
- Constraints: README 冒頭で読みやすい視認性を優先し、詳細説明は README 本文や ARCHITECTURE.md に任せる
- Optional references:
  - `README.md`
  - `ARCHITECTURE.md`
  - `scripts/run_experiment.sh`
  - `scripts/check_scaling.sh`
