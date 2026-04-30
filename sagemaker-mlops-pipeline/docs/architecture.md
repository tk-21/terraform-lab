# SageMaker MLOps Pipeline アーキテクチャ

## 全体構成図

```mermaid
graph TB
    subgraph "データ層"
        DS3[S3 Data Bucket<br/>学習・テストデータ]
    end

    subgraph "SageMaker Pipelines"
        P1[Processing Step<br/>前処理・特徴量エンジニアリング]
        P2[Training Step<br/>モデル学習<br/>スポットインスタンス]
        P3[Evaluation Step<br/>精度評価]
        P4{Condition Step<br/>精度 >= 閾値?}
        P5[Register Step<br/>Model Registry登録<br/>PendingApproval]
        P6[Fail Step<br/>評価不合格通知]
    end

    subgraph "承認フロー"
        MR[Model Registry<br/>PendingApproval]
        CW_N[Chatwork通知<br/>承認依頼]
        APR[人間による承認<br/>Approved]
    end

    subgraph "自動デプロイ"
        EB[EventBridge<br/>Approved検知]
        CP[CodePipeline]
        EP[SageMaker Endpoint<br/>Blue/Greenデプロイ]
    end

    subgraph "監視"
        MM_D[Data Quality Monitor<br/>入力データドリフト]
        MM_M[Model Quality Monitor<br/>予測精度劣化]
        CWA[CloudWatch Alarm]
        CW_A[Chatwork アラート]
        RT[再学習トリガー<br/>Pipeline再実行]
    end

    DS3 --> P1
    P1 --> P2
    P2 --> P3
    P3 --> P4
    P4 -->|Yes| P5
    P4 -->|No| P6
    P5 --> MR
    MR --> CW_N
    CW_N --> APR
    APR --> EB
    EB --> CP
    CP --> EP
    EP --> MM_D
    EP --> MM_M
    MM_D --> CWA
    MM_M --> CWA
    CWA --> CW_A
    CWA --> RT
    RT --> P1
```

## コンポーネント説明

| コンポーネント | 役割 |
|---|---|
| S3 Data Bucket | 学習・テスト・ベースラインデータの格納 |
| S3 Artifacts Bucket | モデルアーティファクト・Pipeline中間成果物の格納 |
| SageMaker Pipelines | ML workflowのオーケストレーション |
| Model Registry | モデルバージョン管理・承認フロー |
| EventBridge | 承認イベントのトリガー |
| CodePipeline | Endpointへの自動デプロイ |
| Model Monitor | データドリフト・モデル品質の継続監視 |
| Lambda | Chatwork通知・再学習トリガー |
| SSM Parameter Store | シークレット・設定値の一元管理 |
