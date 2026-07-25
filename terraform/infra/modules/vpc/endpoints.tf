/**
* Gateway VPC endpoints for S3 and DynamoDB.
*
* Gateway endpoints are free and add a route-table entry that keeps
* traffic to these services on the AWS network instead of the NAT
* path. The API Lambdas run inside the VPC (private-IMAP replumb), so
* without these their fattest flows - the S3 message cache and the
* DynamoDB address tables - would all transit the NAT instance. The
* endpoints also serve the mail-tier containers (generate-config.sh
* scans DynamoDB; message delivery reads S3), which previously egressed
* through NAT for the same calls.
*
* Attached to every route table: private (Lambdas, ECS tasks) and
* public. Interface endpoints for the remaining services (SSM, SNS,
* SQS, Cognito) are deliberately NOT provisioned - they carry an hourly
* charge per AZ, and those calls are thin enough to ride the NAT path.
*/

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.network.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.public.id],
  )
  tags = {
    Name = "cabal-s3-endpoint"
  }
}

resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = aws_vpc.network.id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids = concat(
    aws_route_table.private[*].id,
    [aws_route_table.public.id],
  )
  tags = {
    Name = "cabal-dynamodb-endpoint"
  }
}
