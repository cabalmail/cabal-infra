# cabal-infra
Creates AWS infrastructure and machine configuration for a CabalMail system -- a system for hosting and managing your personal email.

![CabalMail logo](./docs/logo.png)

WARNING: This should not be regarded as an enterprise or ISP-grade email solution. It has been tested on a small pool of users for their personal email. Use at your own risk!

# About TL;DR
CabalMail is a suite of infrastructure code ([Terraform](https://www.terraform.io/)) and configuration management code ([Chef Infra](https://www.chef.io/)) that together create the following system components:

* IMAP hosts
* SMTP relay hosts
* SMTP submission hosts
* Administrative interface for managing addresses
* Other supporting infrastructure

CabalMail allows you to self-host your email and to create unique addresses for all the people, institutions, corporations, etc., with whom you communicate. This allows fine-grained control of who is allowed to insert mail in your inbox.

# About Continued

## Genesis
CabalMail grew out of a bunch of scripts and configuration files that I originally set up when I wanted to take control of my own email hosting. Some time in the late 1990s, I started getting spammed at a third-party address that I had used for years. Spam filters were unreliable at the time, and my inbox quickly became unusable. I reluctantly abandoned that long-held account and went through the pain of contacting all my friends, family, and corporate interloqutors to update my contact information. I resolved to run my own mail system so that I would not have to go through that pain again. Later, when my son graduated from college, he and I made a project out of converting my scripts to Chef cookbooks. It was my son who chose the name "Cabal" for our project. More recently, I added Terraform code to manage the infrastructure.

With CabalMail, you can manage your own self-hosted email system as I do.

But CabalMail is a little different than traditional email.

## Subdomains

What's special about CabalMail is that it forces you to create new subdomains for each address. If we assume your mail domain is example.com, then CabalMail will *not* support addresses of the form foo@example.com. Rather, each address will be hosted at a subdomain of example.com, such as foo@bar.example.com.

By making it easy to create new addresses that point to a given inbox, CabalMail makes it feasible to create new addresses for each person, company, etc., that needs to contact you. This approach is similar to the technique of ["plus-addressing" or "subaddressing"](https://tools.ietf.org/id/draft-newman-email-subaddr-01.html).

"So why not just use plus-addressing?" Good question. See the next section.

## Spam Handling

There isn't any. Nor is there a "Junk" folder (unless a user creates one). By not running Bayesian filters, machine learning algorithms, or other compute-intensive measures, you can operate your own email infrastructure with very small machines. Mine (which serves seven domains and four users) runs just fine on four t2.micros. My monthly AWS cost is less than $100. That's a lot of money in a world of free Gmail accounts, but if you value enhanced control and privacy, you may find it worthwhile as I do. And bear in mind that you can spread the cost among several users.

"But what if I start to get spam?" That's the best part. Simply go to the admin interface and revoke the address. This process does more than simply remove the address from your aliases; it also revokes any related DNS records. Because each address has a unique subdomain, the spam-sending relays can't even find your SMTP servers, so there is no need for your machines to accept the connection, evaluate the reputation of the sender, match the To: header against a list of supported addresses, apply spam filters, etc.

I almost never get spam. And when I do, I have a quick and easy solution.

Moreover, I can easily identify where the leak came from. When I start getting phishing email from a friend, I warn that friend that their account has been compromised. And while I'm at it, I give them a new address with which to contact me. I can confidently identify which friend was affected, even if the phisher spoofs the From: address, as long as I have been careful to give each friend their own unique address at which to contact me.

You _could_ use a CabalMail system along with client-side spam filters, but I recommend against it. Client-side spam filters process mail only after your servers have received and processed it. This hides the spam from you at the cost of gradually (or not-so-gradually) increasing the load on your infrastructure. By making your spam visible, you can easily intercede to reduce load on your infrastructure and keep humming along with small machines. Also, you eliminate false positives; never again will important mail be misidentified as junk.

## Use Case

Admitedly, CabalMail serves a specialized use case, which is definitely not for everyone. (With Google offering free mail with included spam filters, maybe CabalMail isn't for *anyone*.)

To get the benefits of a CabalMail system, you must get used to creating a new email address *each and every time you provide your contact information to a third party.* The administrative interface makes this easy, but it _is_ an additional step.

When I create a new address, I always leave it active until any of the following happen:

* An address gets abused.
* An address starts receiving mail from a different party than the one it was set up for.
* I wish to stop receiving mail from a party *and I have given them a fair opportunity to unsusbscribe me*.

I do not use this system to fool or defraud, and I urge you not to do so either. If you sign up for a service, either free or paid, the provider has a legitimate right to contact you regarding the provision of that service, and they have a right to expect that the information you give them about yourself is true and accurate. However, I do not believe that they have a legitimate expectation that you are giving them the same address that you give others.

# Set Up

## Prerequisites
Before using this repo, you must set up an appropriate environment.

### AWS Account
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

### Fork this repository
Although you could connect Terraform Cloud directly to the original repository, it is safer to fork it. If you want to contribute to it, or extend it for your your own use, then forking is essential. Use the Github URL for your fork where called for in tfvars.

### Terraform
You must install Terraform or set up an account with [Terraform Cloud](https://app.terraform.io/signup/account). HashiCorp offers a free tier. These instructions assume you are using Terraform Cloud.

After signing up, perform the following steps:

1. [Create a worspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-create?in=terraform/cloud-get-started) of type version control workflow. Connect it to your forked repository.
2. Using [terraform.tfvars.example](./terraform.tfvars.example) as a guide, [create variables in your workspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started).
3. [Create environment variables](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started) for `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` using the values you saved from the AWS section step 7. The secret access key should be designated "sensitive". (Don't forget to rotate this key regularly!) Finally, create a third environment variable for `AWS_DEFAULT_REGION`. Set it to the same region you use for your primary infrastructure.

In addition to creating a workspace for this repository, there are two other repositories that will each need their own workspace. See below.

### Domain registration
You must register your desired domains (control and mail) with your chosen registrar. CabalMail requires exactly one control domain and at least one mail domain. Registration requires an email address. You can use a temporary account with any of the free providers for this address, and later, you can update the registration records with a self-hosted address once your hosting infrastructure is up and running.

The control domain is for infrastructure, not for email addresses. If you like to send mail from example.com, you might use example.net as your control domain. If so, then you would retrieve your mail from imap.example.net, send mail to smtp-out.example.net, and manage your addresses at admin.example.net.

### Fork the cabal-dns repository
When you register your control domain, use the [cabal-dns repository](https://github.com/ccarr-cabal/cabal-dns) to create the zone in Route 53. That repo will issue the zone ID in the output. Copy the ID and add it to your tfvars in this repository. This step is not necessary for the mail domains.

Follow the steps above to create a Terraform Cloud workspace for this repository.

1. Queue a plan in your Terraform Cloud workspace.
2. When it finishes the plan phase, confirm and apply. If you are instead using Terraform locally, then create a terraform.tfvars file from the included example, and run Terraform apply:

        terraform init
        terraform plan
        terraform apply

### Fork the cabal-cert repository
Fork the [cabal-cert repository](https://github.com/ccarr-cabal/cabal-cert) to create an SSL certificate.

Follow the steps above to create a Terraform Cloud workspace for this repository.

1. Queue a plan in your Terraform Cloud workspace.
2. When it finishes the plan phase, confirm and apply. If you are instead using Terraform locally, then create a terraform.tfvars file from the included example, and run Terraform apply:

        terraform init
        terraform plan
        terraform apply

## Provisioning

1. Set up the prerequisites above.
2. Queue a plan in your Terraform Cloud workspace.
3. When it finishes the plan phase, confirm and apply. If you are instead using Terraform locally, then create a terraform.tfvars file from the included example, and run Terraform apply:

        terraform init
        terraform plan
        terraform apply

## Post-Automation Steps

### PTR Records
The output contains the IP addresses of each of your outgoing mail relays. In order to send mail reliably, you must [set up PTR records](https://blog.mailtrap.io/ptr-record/) for each outgoing SMTP server. Only AWS can do this for their EIPs, and there is no API, so the process cannot be automated. Fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits) for each outgoing SMTP sever. In addition to creating the necessary PTR records, it will also cause them to relax the rate limit on outgoing mail.

### Name Servers
The output contains the name servers that AWS assigned to your mail domains. To work at all, you must update your registrations with these name servers.