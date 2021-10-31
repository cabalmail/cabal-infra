resource "aws_lambda_permission" "cabal_apigw_lambda_permission" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cabal_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = join("", [
    join(":", [
      "arn:aws:execute-api",
      var.region,
      var.account,
      var.gateway_id
    ]),
    "/*/",
    aws_api_gateway_method.cabal_method.http_method,
    aws_api_gateway_resource.cabal_resource.path
  ])
}

resource "aws_iam_role" "cabal_lambda_role" {
  name = "${var.name}_role"

  assume_role_policy = <<ROLEPOLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": "${var.name}Sid"
    }
  ]
}
ROLEPOLICY
}

resource "aws_iam_role_policy" "cabal_lambda_policy" {
  name   = "${var.name}_policy"
  role   = aws_iam_role.cabal_lambda_role.id
  policy = <<RUNPOLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "logs:CreateLogGroup",
            "Resource": "arn:aws:logs:${var.region}:*:*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": [
                "arn:aws:logs:${var.region}:*:log-group:/aws/lambda/${aws_lambda_function.cabal_lambda.function_name}:*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:BatchGetItem",
                "dynamodb:DescribeTable",
                "dynamodb:GetItem",
                "dynamodb:ListTables",
                "dynamodb:Query",
                "dynamodb:Scan",
                "dynamodb:PutItem",
                "dynamodb:ListTagsOfResource",
                "dynamodb:ListGlobalTables",
                "dynamodb:DescribeGlobalTable"
            ],
            "Resource": [
                "arn:aws:dynamodb:${var.region}:*:table/cabal-addresses"
            ]
        }
    ]
}
RUNPOLICY
}

# resource "aws_iam_role_policy_attachment" "cabal_lambda_policy_attachment" {
#   role       = aws_iam_role.cabal_lambda_role.name
#   policy_arn = aws_iam_policy.cabal_lambda_policy.arn
# }

resource "aws_lambda_function" "cabal_lambda" {
  filename = "${var.name}_lambda.zip"
  source_code_hash = data.archive_file.cabal_lambda_zip.output_base64sha256
  function_name = var.name
  role = aws_iam_role.cabal_lambda_role.arn
  handler = "index.handler"
  runtime = var.runtime
}
