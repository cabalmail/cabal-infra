/**
* CloudFront access logging via CloudWatch vended-log delivery (standard
* logging v2).
*
* CloudFront offers two logging mechanisms. The legacy one ("standard
* logging (legacy)") is the `logging_config` block on the distribution
* itself, and it delivers through a bucket ACL grant to the log-delivery
* group. That path is incompatible with this stack: every bucket here is
* created with Object Ownership BucketOwnerEnforced (ACLs disabled), and
* re-enabling ACLs on a log bucket to satisfy it would be a step
* backwards. This module uses the modern path instead - CloudWatch vended
* log delivery - which authorizes delivery with a bucket *policy* grant to
* the delivery.logs.amazonaws.com service principal and needs no ACLs at
* all. The grant lives with the bucket, in modules/s3_access_logs.
*
* Three resources per delivery, following the AWS docs ("Configure
* standard logging (v2)"):
*   delivery source      - one per distribution, names the log type
*   delivery destination - one shared, names the S3 bucket and format
*   delivery             - joins a source to the destination
*
* Everything here must live in us-east-1. CloudFront is a global service
* and its delivery configuration is only accepted there, so the root
* passes this module the us-east-1 provider as its default `aws`. The
* destination bucket does *not* have to be in us-east-1: cross-Region
* delivery is explicitly supported ("you must specify the US East (N.
* Virginia) Region, even if you want to enable cross Region delivery to
* another destination"), so logs land in the same shared bucket in the
* stack region as every other access log.
*
* Retention is inherited: the shared bucket's lifecycle rule is unfiltered
* and expires everything after 180 days, CloudFront logs included.
*/

# One delivery source per distribution. AWS permits only one delivery
# source per distribution, so the map key - not the distribution id -
# keeps the names stable and readable.
resource "aws_cloudwatch_log_delivery_source" "cloudfront" {
  for_each = var.distributions

  name         = "cabal-${each.key}-access-logs"
  log_type     = "ACCESS_LOGS"
  resource_arn = each.value
}

# One shared destination for both distributions. Note that output_format
# is immutable: AWS only accepts it at creation, so changing it later
# means destroying and recreating the destination (and the deliveries
# that reference it). w3c matches the legacy CloudFront log layout, which
# is what most off-the-shelf log tooling expects.
resource "aws_cloudwatch_log_delivery_destination" "s3" {
  name          = "cabal-cloudfront-access-logs-s3"
  output_format = "w3c"

  delivery_destination_configuration {
    destination_resource_arn = var.destination_bucket_arn
  }
}

# Joining source to destination is what actually starts delivery.
#
# suffix_path is appended to the default prefix CloudFront applies when
# the destination ARN carries no prefix of its own
# (AWSLogs/<account-id>/CloudFront/), so the delivered objects land at
# AWSLogs/<account-id>/CloudFront/<key>/<distribution-id>/<yyyy>/<MM>/<dd>/.
# The bucket policy grants that whole subtree; keep the two in step, since
# a suffix_path that escapes the granted prefix fails delivery silently.
resource "aws_cloudwatch_log_delivery" "cloudfront" {
  for_each = var.distributions

  delivery_source_name     = aws_cloudwatch_log_delivery_source.cloudfront[each.key].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.s3.arn

  s3_delivery_configuration {
    suffix_path                 = "${each.key}/{DistributionId}/{yyyy}/{MM}/{dd}"
    enable_hive_compatible_path = false
  }
}
