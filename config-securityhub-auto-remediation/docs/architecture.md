# CSAR アーキテクチャ図

## 全体フロー

```mermaid
graph TB
    subgraph "検知層"
        CR[Config Recorder] -->|変更記録| CRule[Config Rules × 8]
        SH[Security Hub] -->|Findings集約| SHF[Security Hub Findings]
    end

    subgraph "ルーティング層 (EventBridge)"
        CRule -->|NON_COMPLIANT| EB_S3[EB Rule: S3]
        CRule -->|NON_COMPLIANT| EB_IAM[EB Rule: IAM]
        CRule -->|NON_COMPLIANT| EB_SG[EB Rule: SG]
        CRule -->|NON_COMPLIANT| EB_RDS[EB Rule: RDS]
        SHF -->|Custom Action| CA_S3[Custom Action: S3]
        SHF -->|Custom Action| CA_IAM[Custom Action: IAM]
        SHF -->|Custom Action| CA_SG[Custom Action: SG]
        SHF -->|Custom Action| CA_RDS[Custom Action: RDS]
        CA_S3 --> EB_S3
        CA_IAM --> EB_IAM
        CA_SG --> EB_SG
        CA_RDS --> EB_RDS
    end

    subgraph "修復層 (Lambda / VPC Private Subnet)"
        EB_S3 --> LS3[Lambda: S3修復]
        EB_IAM --> LIAM[Lambda: IAM修復]
        EB_SG --> LSG[Lambda: SG修復]
        EB_RDS --> LRDS[Lambda: RDS修復]
    end

    subgraph "修復アクション"
        LS3 -->|Block Public Access\nSSE設定| S3R[S3バケット]
        LIAM -->|LoginProfile削除\n監査ログ記録| IAMR[IAMユーザー]
        LSG -->|RevokeIngress 0.0.0.0/0:22| SGR[Security Group]
        LRDS -->|PubliclyAccessible=false\nSnapshot取得| RDSR[RDS DB]
    end

    subgraph "記録・監視層"
        LS3 & LIAM & LSG & LRDS --> DDB[(DynamoDB\ncsar-remediation-log)]
        LS3 & LIAM & LSG & LRDS --> S3A[(S3\ncsar-audit-logs)]
        LS3 & LIAM & LSG & LRDS -->|3回リトライ後失敗| DLQ[SQS DLQ]
    end

    subgraph "可視化・アラート"
        DDB & S3A & DLQ --> DASH[CloudWatch Dashboard\nCSAR-AutoRemediation]
        DLQ -->|深度 ≥ 1| SNS[SNS Topic\ncsar-alerts]
        DASH --> SNS
    end
```

## コスト構成 (月次概算)
| サービス | 想定コスト |
|---------|-----------|
| Config (8ルール × 記録) | ~$2-5 |
| Security Hub | ~$1-3 |
| Lambda (月100回以下) | 無料枠内 |
| DynamoDB (PAY_PER_REQUEST) | ~$1未満 |
| S3監査ログ (Intelligent-Tiering) | ~$1未満 |
| CloudWatch Dashboard | $3/Dashboard |
| **合計** | **$10-15/月** |

## EventBridge配線マトリクス

| Config Rule | EventBridge Rule | Lambda関数 |
|------------|-----------------|-----------|
| csar-s3-bucket-public-read-prohibited | csar-config-s3-noncompliant | csar-remediation-s3 |
| csar-s3-bucket-server-side-encryption-enabled | csar-config-s3-noncompliant | csar-remediation-s3 |
| csar-iam-user-mfa-enabled | csar-config-iam-noncompliant | csar-remediation-iam |
| csar-iam-user-no-policies-check | csar-config-iam-noncompliant | csar-remediation-iam |
| csar-restricted-ssh | csar-config-sg-noncompliant | csar-remediation-ec2-sg |
| csar-restricted-rdp | csar-config-sg-noncompliant | csar-remediation-ec2-sg |
| csar-rds-storage-encrypted | csar-config-rds-noncompliant | csar-remediation-rds |
| csar-rds-instance-public-access-check | csar-config-rds-noncompliant | csar-remediation-rds |
