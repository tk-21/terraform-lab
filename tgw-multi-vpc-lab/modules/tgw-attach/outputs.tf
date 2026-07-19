output "attachment_id" {
  description = "VPCアタッチメントのID（Phase3でルートテーブル関連付けに使用）"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

output "vpc_id" {
  description = "アタッチされたVPCのID"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.vpc_id
}

output "attachment_name" {
  description = "アタッチメントの識別名"
  value       = var.attachment_name
}
