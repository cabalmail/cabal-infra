# Recommended Steps for Setting Up an Amazon Web Services Account

You must [sign up for an Amazon Web Services account](https://portal.aws.amazon.com/billing/signup#/start). You may use an existing account, but I recommend creating a dedicated account for this workload.

After signing up, perform the following steps:

1. [Add MFA to your root account](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_root-user.html#id_root-user_manage_mfa).
2. [Create an IAM group](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_groups_create.html) called "console" and attach the Amazon-managed AdministratorAccess policy.
3. [Create an IAM user](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_users_create.html#id_users_create_console) called whatever you like for your own console access and attach the just-created "console" group. This user should be console-only with no programmatic access. Never use the root account again if you can help it.
4. Log in with the IAM user.
5. [Create an IAM policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_create-console.html) called "cicd" with the following permissions:

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
                    "application-autoscaling:*",
                    "autoscaling:*",
                    "backup:*",
                    "backup-storage:*",
                    "cloudfront:*",
                    "cloudwatch:DeleteAlarms",
                    "cloudwatch:DescribeAlarms",
                    "cloudwatch:ListTagsForResource",
                    "cloudwatch:PutMetricAlarm",
                    "cloudwatch:TagResource",
                    "cloudwatch:UntagResource",
                    "cognito-identity:*",
                    "cognito-idp:*",
                    "dynamodb:*",
                    "ec2:*",
                    "ecr:*",
                    "ecs:*",
                    "elasticfilesystem:*",
                    "elasticloadbalancing:*",
                    "iam:*",
                    "imagebuilder:*",
                    "kms:CreateAlias",
                    "kms:CreateGrant",
                    "kms:CreateKey",
                    "kms:DeleteAlias",
                    "kms:DescribeKey",
                    "kms:GetKeyPolicy",
                    "kms:GetKeyRotationStatus",
                    "kms:ListAliases",
                    "kms:ListResourceTags",
                    "kms:PutKeyPolicy",
                    "kms:ScheduleKeyDeletion",
                    "kms:TagResource",
                    "kms:UntagResource",
                    "kms:UpdateAlias",
                    "kms:UpdateKeyDescription",
                    "lambda:*",
                    "logs:CreateLogGroup",
                    "logs:DescribeLogGroups",
                    "logs:ListTagsForResource",
                    "logs:ListTagsLogGroup",
                    "logs:PutRetentionPolicy",
                    "logs:TagResource",
                    "route53:ActivateKeySigningKey",
                    "route53:ChangeResourceRecordSets",
                    "route53:ChangeTagsForResource",
                    "route53:CreateHostedZone",
                    "route53:CreateKeySigningKey",
                    "route53:DeactivateKeySigningKey",
                    "route53:DeleteHostedZone",
                    "route53:DeleteKeySigningKey",
                    "route53:DisableHostedZoneDNSSEC",
                    "route53:EnableHostedZoneDNSSEC",
                    "route53:GetChange",
                    "route53:GetDNSSEC",
                    "route53:GetHostedZone",
                    "route53:ListHostedZonesByName",
                    "route53:ListResourceRecordSets",
                    "route53:ListTagsForResource",
                    "s3:*",
                    "s3-object-lambda:*",
                    "scheduler:*",
                    "servicediscovery:*",
                    "sms-voice:DescribePhoneNumbers",
                    "sms-voice:ListTagsForResource",
                    "sms-voice:ReleasePhoneNumber",
                    "sms-voice:RequestPhoneNumber",
                    "sms-voice:TagResource",
                    "sns:*",
                    "sqs:*",
                    "ssm:*",
                    "sts:GetCallerIdentity"
                ],
                "Resource": "*"
            }
        ]
    }
    ```
    (If you don't intend to use this repo to configure AWS Backup, then you may omit the `backup:*` and `backup-storage:*` lines. If you do enable backups (`TF_VAR_BACKUP`), one additional one-time CLI step - the advanced DynamoDB backup-features opt-in - is required for cross-region copy; see [Disaster recovery](./disaster-recovery.md).)

    (If you don't intend to enable DNSSEC signing (`TF_VAR_DNSSEC_ENABLED`, off by default), you may omit every `kms:` line except `kms:CreateGrant` and `kms:DescribeKey`, and the six `route53:` lines that mention `KeySigningKey` or `DNSSEC` except `route53:GetDNSSEC`, which Terraform reads unconditionally. See [DNSSEC](./dnssec.md).)

    (If you don't intend to enable SMS verification through AWS End User Messaging (`TF_VAR_USE_EUM_SMS`, off by default), you may omit the five `sms-voice:` lines. If you do enable it, completing the toll-free verification registration requires an additional one-time policy; see [SMS toll-free verification setup](./sms-tfv-setup.md).)

    (`imagebuilder:*` covers the EC2 Image Builder pipeline that bakes the custom NAT instance AMI. `scheduler:*` covers the EventBridge Scheduler schedules for certificate renewal and DMARC report processing.)

    (Terraform state access is covered by `s3:*`. If your state bucket lives in a different AWS account than the one you are setting up here, that bucket's policy must also grant this user access; no extra statements are needed in this policy.)
6. Create an IAM Group called "cicd" and assign the above policy.
7. Create an IAM User called "cicd" and assign the above group. This user should be progamatic only -- *no console*. Make a note of the API key ID and secret. You will need them when you set up Terraform and GitHub. Note: you should rotate this key regularly!
8. Optional but recommended: delete the default VPC in all regions.

If you have followed the recommendation to create a dedicated account, then the above steps should be the *only* manual steps required in this account. Everything else should be managed by Terraform.
