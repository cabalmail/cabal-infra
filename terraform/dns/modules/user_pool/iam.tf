resource "aws_iam_role" "users" {
  name               = "cabal_sns_role"
  assume_role_policy = data.aws_iam_policy_document.users.json
}

resource "aws_iam_policy" "sns" {
  name   = "cabal_sns_role_policy"
  policy = data.aws_iam_policy_document.sns_users.json
}

resource "aws_iam_policy" "s3_cognito" {
  name   = "cabal_s3_cognito_policy"
  policy = data.aws_iam_policy_document.cognito_to_s3.json
}

resource "aws_iam_role_policy_attachment" "sns" {
  role       = aws_iam_role.users.name
  policy_arn = aws_iam_policy.sns.arn
}

resource "aws_iam_role_policy_attachment" "users" {
  role   = aws_iam_role.users.name
  policy = aws_iam_policy.s3_cognito.arn
}