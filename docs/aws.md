# Recommended Steps for Setting Up an Amazon Web Services Account

You must [sign up for an Amazon Web Services account](https://portal.aws.amazon.com/billing/signup#/start). You may use an existing account, but I recommend creating a dedicated account for this workload.

After signing up, perform the following steps:

1. [Add MFA to your root account](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#id_root-user_manage_mfa).
2. [Create an IAM group](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups_create.html) called "console" and attach the Amazon-managed AdministratorAccess policy.
3. [Create an IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_console) called whatever you like for your own console access and attach the just-created "console" group. This user should be console-only with no programmatic access. Never use the root account again if you can help it.
4. Log in with the IAM user.
5. [Create an IAM policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_create-console.html) called "terraform" with the following permissions:

    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "Vicious",
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
                    "backup:*",
                    "backup-storage:*"
                    "cloudfront:*",
                    "cognito-identity:*",
                    "cognito-idp:*",
                    "dynamodb:*",
                    "ec2:*",
                    "ecr:*",
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
                    "route53:GetDNSSEC",
                    "route53:GetHostedZone",
                    "route53:ListHostedZonesByName",
                    "route53:ListResourceRecordSets",
                    "route53:ListTagsForResource",
                    "s3:*",
                    "s3-object-lambda:*",
                    "ssm:*",
                    "sts:GetCallerIdentity"
                ],
                "Resource": "*"
            }
        ]
    }
    ```
    (If you don't intend to use this repo to configure AWS Backup, then you may omit the `backup:*` and `backup-storage:*` lines.)
6. Create an IAM Group called "terraform" and assign the above policy.
7. Create an IAM User called "terraform" and assign the above group. This user should be progamatic only -- *no console*. Save the API key ID and secret. You will need them when you set up Terraform. Note: you should rotate this key regularly!
8. Create an IAM policy called "github" with the following permissions:

    ```json
    {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "TheSloth",
                "Effect": "Allow",
                "Action": [
                    "s3:DeleteObject",
                    "s3:GetObject",
                    "s3:GetObjectAcl",
                    "s3:ListAllMyBuckets",
                    "s3:ListBucket",
                    "s3:PutObject",
                    "s3:PutObjectAcl"
                ],
                "Resource": "*"
            },
            {
                "Sid": "NeyOperaHouse",
                "Effect": "Allow",
                "Action": [
                    "ssm:GetParameter",
                    "ssm:GetParameters",
                    "ssm:GetParametersByPath"
                ],
                "Resource": "arn:aws:ssm:*:*:parameter//cabal/react-config/*"
            }
        ]
    }
    ```

9. Create an IAM Group called "github" and assign the above policy.
10. Create an IAM User called "github" and assign the above group. This user should be progamatic only -- *no console*. Save the API key ID and secret. You will need them when you set up Github. Note: you should rotate this key regularly!
11. Optional but recommended: delete the default VPC in all regions.

If you have followed the recommendation to create a dedicated account, then the above steps should be the *only* manual steps required in this account. Everything else should be managed by Terraform.