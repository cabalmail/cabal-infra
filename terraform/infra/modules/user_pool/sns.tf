resource "aws_iam_role" "users" {
  name               = "cabal_sns_role"
  assume_role_policy = data.aws_iam_policy_document.sns_users.json
}

data "aws_iam_policy_document" "sns_users" {
  statement {
    actions = [
      "sns:Publish",
    ]

    resources = [
      "*",
    ]
  }
}

resource "aws_iam_policy" "users" {
  name   = "cabal_sns_role_policy"
  policy = data.aws_iam_policy_document.users.json
}

resource "aws_iam_role_policy_attachment" "users" {
  role       = aws_iam_role.users.name
  policy_arn = aws_iam_policy.users.arn
}