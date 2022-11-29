resource "aws_iam_role" "users" {
  name               = "cabal_sns_role"
  assume_role_policy = data.aws_iam_policy_document.users.json
}

resource "aws_iam_policy" "sns" {
  name   = "cabal_sns_role_policy"
  policy = data.aws_iam_policy_document.sns_users.json
}

data "aws_iam_policy_document" "cognito_to_s3" {
  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.react_app.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"]
    }
  }
  statement {
    actions   = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::${aws_s3_bucket.react_app.id}/message-cache/${"$"}{cognito-identity.amazonaws.com:sub}/*"
    ]
  }
}

resource "aws_iam_role_policy_attachment" "sns" {
  role       = aws_iam_role.users.name
  policy_arn = aws_iam_policy.sns.arn
}

resource "aws_iam_role_policy_attachment" "users" {
  role   = aws_iam_role.users.name
  policy = aws_iam_policy_document.cognito_to_s3.json
}