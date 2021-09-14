provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      managed_by_terraform = "y"
      terraform_repo       = var.repo
    }
  }
}

resource "aws_s3_bucket" "cabal_cookbook_bucket" {
  acl           = "private"
  bucket_prefix = "cabal-artifacts-"
}

resource "aws_s3_bucket_object" "cabal_cookbook_files" {
  for_each = fileset(path.module, "cookbooks/**/*")

  bucket = aws_s3_bucket.cabal_cookbook_bucket.bucket
  key    = each.value
  source = "${path.module}/${each.value}"
  etag   = filemd5("${path.module}/${each.value}")
}

module "cabal_table" {
  source     = "./modules/table"
}

module "cabal_vpc" {
  source     = "./modules/vpc"
  cidr_block = var.cidr_block
  az_list    = var.availability_zones
}

module "cabal_load_balancer" {
  source         = "./modules/elb"
  public_subnets = module.cabal_vpc.public_subnets
  vpc            = module.cabal_vpc.vpc
  control_domain = var.control_domain
  zone_id        = var.zone_id
}

module "cabal_efs" {
  source           = "./modules/efs"
  vpc              = module.cabal_vpc.vpc
  private_subnets  = module.cabal_vpc.private_subnets
}

# TODO
# Create DynamoDB Table

module "cabal_imap" {
  source           = "./modules/imap"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = aws_s3_bucket.cabal_cookbook_bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = aws_s3_bucket.cabal_cookbook_bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  depends_on       = [
    aws_s3_bucket_object.cabal_cookbook_files
  ]
}

module "cabal_smtp_in" {
  source           = "./modules/smtp"
  type             = "in"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = aws_s3_bucket.cabal_cookbook_bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = aws_s3_bucket.cabal_cookbook_bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  depends_on       = [
    aws_s3_bucket_object.cabal_cookbook_files
  ]
}

module "cabal_smtp_out" {
  source           = "./modules/smtp"
  type             = "out"
  private_subnets  = module.cabal_vpc.private_subnets
  vpc              = module.cabal_vpc.vpc
  control_domain   = var.control_domain
  artifact_bucket  = aws_s3_bucket.cabal_cookbook_bucket.id
  target_group_arn = module.cabal_load_balancer.imap_tg.arn
  table_arn        = module.cabal_table.table_arn
  s3_arn           = aws_s3_bucket.cabal_cookbook_bucket.arn
  efs_dns          = module.cabal_efs.efs_dns
  depends_on       = [
    aws_s3_bucket_object.cabal_cookbook_files
  ]
}

# TODO
# Create user pool
# Create lambda/api-gateway admin application
# Add some users