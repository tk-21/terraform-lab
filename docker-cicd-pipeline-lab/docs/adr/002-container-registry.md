# ADR 002 — コンテナレジストリの選定

## ステータス
採用

## 背景
[なぜプライベートレジストリが必要か、どんな要件があったかを書く]

## 決定
Amazon ECR を採用する

## 理由
[ECR を選んだ理由: IAM 統合、VPC Endpoint、コストなどを自分の視点で]

## トレードオフ
[ECR の制約や課題点]

## 代替案
- Docker Hub (Private)
- GitHub Container Registry (ghcr.io)
- Artifact Registry (GCP)
