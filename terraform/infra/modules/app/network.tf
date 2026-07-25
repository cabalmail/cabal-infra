/**
* Shared security group for the VPC-attached API Lambdas.
*
* The Lambdas moved inside the VPC so they can reach the imap container
* over the Cloud Map internal name (143 + STARTTLS) instead of the
* public IMAPS listener - the prerequisite for closing public IMAP
* access entirely. One group serves every function the call module
* stamps out plus append_sent and process_dmarc: they share an identical
* network posture (originate-only), so per-function groups would add
* drift surface without adding isolation.
*
* No ingress: nothing dials a Lambda. Egress stays open because the
* functions collectively need SSM, Cognito, SNS, SQS, Route 53, S3,
* DynamoDB, external DNS/HTTPS (fetch_bimi), SMTP submission (send),
* and IMAP - an allowlist here would just restate "most of the
* internet" and break quietly on the next endpoint.
*/

resource "aws_security_group" "lambda" {
  name        = "cabal-lambda-api-sg"
  description = "API Lambda functions (VPC-attached for private IMAP access)"
  vpc_id      = var.vpc_id
}

resource "aws_security_group_rule" "lambda_egress" {
  #checkov:skip=CKV_AWS_382:originate-only functions collectively need SSM, Cognito, SNS, SQS, Route 53, external DNS/HTTPS, SMTP, and IMAP; a port allowlist would restate most of the internet (matches the mail-tier egress posture)
  type              = "egress"
  protocol          = "-1"
  from_port         = 0
  to_port           = 0
  cidr_blocks       = ["0.0.0.0/0"] #tfsec:ignore:aws-vpc-no-public-egress-sgr
  ipv6_cidr_blocks  = ["::/0"]      #tfsec:ignore:aws-vpc-no-public-egress-sgr
  description       = "Allow all outgoing"
  security_group_id = aws_security_group.lambda.id
}
