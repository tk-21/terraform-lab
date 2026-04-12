# Terraform destroy ランブック

対象: 検証環境の後片付け  
想定読者: Terraform 実行者

## 推奨手順

```bash
make destroy-prep
make tf-destroy
```

## destroy-prep でやっていること

- `knowledgebot` Namespace の `Ingress` / `Service` / `Deployment` などを先に削除
- internal ALB 由来の ENI や Security Group が残りにくいようにする
- VPC 内の残存 ENI / Security Group を確認する

## よくある失敗と対処

### ECR が `RepositoryNotEmpty`

- 既存イメージが残っている
- 現在は ECR repository に `force_delete = true` を設定済み
- それでも残る場合は `aws ecr batch-delete-image` で手動削除する

### Subnet が `DependencyViolation`

- 多くは ALB 由来 ENI が残っている
- `describe-network-interfaces` で `ELB` を含む ENI を確認する

### VPC が `DependencyViolation`

- Security Group が残っていることがある
- 多くは ENI に紐づいているため、先に ENI 側の削除完了を待つ

## 注意点

- `terraform destroy` は必ず `apply` と同じ `tfvars` を指定する
- `destroy` 前に `enable_lbc` などを変えない
- NAT Gateway や ALB の削除待ちで 10 分以上かかることがある
