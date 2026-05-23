# README Hero Spec

README 用のヒーロー画像を作る前に、このファイルを埋める。
プロジェクトごとの差分をここに寄せることで、毎回の指示を短くできる。

## Basic
- Project name: `ai-inference-pipeline`
- Audience: AWS / Terraform / 生成AI の実践力を README から素早く伝えたい採用担当者・学習者
- Primary language: Japanese
- Output path: `docs/readme-hero.svg`

## Messaging
- One-line summary: S3 にファイルを置くだけで、前処理から Bedrock 推論と Chatwork 通知まで自動実行される AI 推論パイプライン
- What should be understood at a glance: イベント駆動の E2E 構成、Terraform 管理、コスト最適化を意識した AWS 設計
- Top 3 selling points:
  - S3 → Step Functions → ECS → Lambda/Bedrock → DynamoDB → Chatwork の一連フローを一枚で伝える
  - NAT Gateway 不使用、Fargate Spot、arm64 などコスト意識のある設計を示す
  - ハンズオン README の冒頭で「何を作るか」「何が学べるか」が瞬時に伝わる

## Visual Direction
- Tone: 実務的、信頼感がありつつ少し先進的
- Color hints: Deep navy base, teal/green accents, amber highlights
- Preferred layout: 左にメッセージ、中央にパイプライン、右に訴求ポイントの 3 カラム
- Avoid: スクリーンショット風、情報過多、小さすぎる文字、装飾だけで意味が伝わらない図

## Content Inputs
- Key services / technologies:
  - Amazon S3 / EventBridge
  - AWS Step Functions / ECS Fargate / Lambda
  - Amazon Bedrock / DynamoDB / Chatwork / Terraform
- Flow to visualize:
  1. S3 `input/` へ CSV をアップロード
  2. EventBridge 経由で Step Functions が起動
  3. ECS Fargate が前処理し、Lambda が Bedrock Claude Haiku で推論
  4. DynamoDB 永続化と Chatwork 通知まで完走
- Labels or phrases to include:
  - `AWS AI HANDS-ON`
  - `Pipeline Overview`
  - `No NAT Gateway` / `Retry / Catch` / `IAM lock on model`

## README Placement
- Insert position: タイトルと概要文の直下、最初の区切り線の前
- Markdown or HTML: HTML (`<img width="100%">`)
- Existing image to replace: none

## Notes
- Constraints: GitHub README で視認しやすい横長構成、画像だけで概要を掴めること、日本語本文と相性のよい表現
- Optional references: `README.md`, `ARCHITECTURE.md`, `phase6.md`
