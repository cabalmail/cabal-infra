# Recommended Steps for Setting Up an AWS Account

You must [sign up for an AWS account](https://portal.aws.amazon.com/billing/signup#/start). You may use an existing account, but I recommend creating a dedicated account for this workload.

After signing up, perform the following steps:

1. [Add MFA to your root account](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#id_root-user_manage_mfa).
2. [Create an IAM group](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups_create.html) and attach the Amazon-managed AdministratorAccess policy.
3. [Create an IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_console) for your own console access and attach the just-created group. This user should be console-only with no programmatic access. Never use the root account again if you can help it.
4. Log in with the IAM user.
5. [Create an IAM policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_create-console.html) called "terraform" with the following permissions:

    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "SidTheGreater",
                "Effect": "Allow",
                "Action": [
                    "acm:AddTagsToCertificate",
                    "acm:DeleteCertificate",
                    "acm:DescribeCertificate",
                    "acm:ImportCertificate",
                    "acm:ListTagsForCertificate",
                    "acm:RenewCertificate",
                    "acm:RequestCertificate",
                    "apigateway:*",
                    "autoscaling:*",
                    "cloudfront:*",
                    "cognito-identity:*",
                    "cognito-idp:*",
                    "dynamodb:*",
                    "ec2:*",
                    "elasticfilesystem:*",
                    "elasticloadbalancing:*",
                    "iam:*",
                    "kms:CreateGrant",
                    "kms:DescribeKey",
                    "lambda:*",
                    "route53:ChangeResourceRecordSets",
                    "route53:ChangeTagsForResource",
                    "route53:CreateHostedZone",
                    "route53:DeleteHostedZone",
                    "route53:GetChange",
                    "route53:GetHostedZone",
                    "route53:ListHostedZonesByName",
                    "route53:ListResourceRecordSets",
                    "route53:ListTagsForResource",
                    "s3:*",
                    "s3-object-lambda:*",
                    "ssm:*",
                    "secretsmanager:GetRandomPassword",
                    "secretsmanager:ListSecrets",
                    "sts:GetCallerIdentity"
                ],
                "Resource": "*"
            },
            {
                "Sid": "SidTheLesser",
                "Effect": "Allow",
                "Action": [
                    "secretsmanager:UntagResource",
                    "secretsmanager:DescribeSecret",
                    "secretsmanager:DeleteResourcePolicy",
                    "secretsmanager:PutSecretValue",
                    "secretsmanager:CreateSecret",
                    "secretsmanager:DeleteSecret",
                    "secretsmanager:CancelRotateSecret",
                    "secretsmanager:ListSecretVersionIds",
                    "secretsmanager:UpdateSecret",
                    "secretsmanager:GetResourcePolicy",
                    "secretsmanager:GetSecretValue",
                    "secretsmanager:PutResourcePolicy",
                    "secretsmanager:RestoreSecret",
                    "secretsmanager:RotateSecret",
                    "secretsmanager:UpdateSecretVersionStage",
                    "secretsmanager:ValidateResourcePolicy",
                    "secretsmanager:TagResource"
                ],
                "Resource": "arn:aws:secretsmanager:*:715401949493:secret:/cabal/*"
            }
        ]
    }
    ```

6. Create an IAM Group called "terraform" and assign the above policy.
7. Create an IAM User called "terraform" and assign the above group. This user should be progamatic only -- *no console*. Save the API key ID and secret. Note: you should rotate this key regularly!

If you have followed the recommendation to create a dedicated account, then the above steps should be the *only* manual steps required in this account. Everything else should be managed by Terraform.