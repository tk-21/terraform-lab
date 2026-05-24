# IAM概念比較

| 概念 | AWS | GCP | Azure |
|------|-----|-----|-------|
| 権限の単位 | Policy（JSON）| Role（YAML/JSON）| Role Definition |
| アタッチ対象 | User/Group/Role | Service Account / Group | Service Principal / Managed Identity |
| リソースへの付与 | IAM Role → EC2 Instance Profile | Service Account → VM | Managed Identity → VM |
| スコープ | Account / Resource ARN | Project / Folder / Org | Subscription / RG / Resource |
| 最小権限の実現 | Inline Policy or 細かいManaged Policy | Predefined Role or Custom Role | Built-in Role or Custom Role |

## IAMの設計思想の違い

### AWSのIAM
- リソースベースポリシー（バケットポリシー等）とアイデンティティベースポリシーの2軸
- ARNで全リソースをアドレス可能なため、クロスアカウント制御が強力

### GCPのIAM
- 「誰が」「何に」「何を」の3要素がシンプル
- リソース階層（Org > Folder > Project > Resource）での継承が直感的

### AzureのIAM
- RBACとAzure AD（Entra ID）の連携が複雑だがEnterpriseでは強力
- Managed Identityで「アプリ自体に権限を持たせる」思想がAWSのInstance Profileに近い

## 所感（自分の言葉で書くこと）

<!-- AI生成禁止 -->

### 3クラウドを比較して「AWSのIAMのここが使いやすい / 使いにくい」と感じたこと

（ここに記述）
