data "aws_iam_policy_document" "cabal_sns_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["cognito-idp.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cabal_sns_role" {
  name               = "cabal_sns_role"
  assume_role_policy = "${data.aws_iam_policy_document.cabal_sns_assume_role_policy.json}"
}

data "aws_iam_policy_document" "cabal_sns_publish_policy" {
  statement {
    actions = [
      "sns:Publish",
    ]

    resources = [
      "*",
    ]
  }
}

resource "aws_iam_policy" "cabal_sns_role_policy" {
  name   = "cabal_sns_role_policy"
  policy = "${data.aws_iam_policy_document.cabal_sns_publish_policy.json}"
}

resource "aws_iam_role_policy_attachment" "cabal_sns_role_policy_attachment" {
  role       = "${aws_iam_role.cabal_sns_role.name}"
  policy_arn = "${aws_iam_policy.cabal_sns_role_policy.arn}"
}