provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge(
      {
        ManagedBy = "terraform"
        Env       = var.env
      },
      var.tags
    )
  }
}
