# --- Private subnets (AZ分散) ---
variable "private_subnet_cidrs" {
  type        = map(string)
  description = "Private subnet CIDRs by AZ suffix (e.g., { a = 10.0.11.0/24, d = 10.0.12.0/24 })"
  default = {
    a = "10.0.11.0/24"
    d = "10.0.12.0/24"
  }
}

resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${var.aws_region}${each.key}"

  # privateなので public ip は付けない
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.base_name}-subnet-private-${each.key}"
    Tier = "private"
  }
}

# --- NAT Gateway (まずは1基: コスト優先) ---
# NATを置くためのEIP
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.base_name}-eip-nat" }
}

# NATは public subnet のどれか1つに置く（例: a）
# publicサブネットが a/d など変わるので、最初のキーを使う
locals {
  public_subnet_first_key = element(sort(keys(aws_subnet.public)), 0)
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.public_subnet_first_key].id

  tags = { Name = "${local.base_name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# --- private route table: default route -> NAT ---
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.base_name}-rt-private" }
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

# ===============================
# ★ S3 VPC Endpoint（ここ）
# ===============================
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"

  # private subnet が使う route table に関連付け
  route_table_ids = [aws_route_table.private.id]

  tags = { Name = "${local.base_name}-vpce-s3" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

output "private_subnet_ids" {
  value = { for k, s in aws_subnet.private : k => s.id }
}
