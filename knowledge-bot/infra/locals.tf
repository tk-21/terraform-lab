locals {
  name = var.project_name
  tags = {
    Project = var.project_name
    Owner   = var.owner
  }
}
