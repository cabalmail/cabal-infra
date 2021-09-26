# cabal-infra
Creates AWS infrastructure and machine configuration for a CabalMail system -- a system for hosting and managing your personal email.

WARNING: This should not be regarded as an enterprise or ISP-grade email solution. It has been tested on a small pool of users for their personal email. Use at your own risk!

# About
CabalMail is a suite of infrastructure code ([Terraform](https://www.terraform.io/)) and configuration management code ([Chef Infra](https://www.chef.io/)) that together create the following system components:

* IMAP hosts
* SMTP relay hosts
* SMTP submission hosts
* Administrative interface for managing addresses
* Other supporting infrastructure

CabalMail grew out of a bunch of scripts and configuration files that I originally set up when I wanted to take control of my own email hosting. Some time in the late 1990s, I started getting spammed at a third-party address that I had used for years. Spam filters were unreliable at the time, and my inbox quickly became unusable. I reluctantly abandoned that long-held account and went through the pain of contacting all my friends, family, and corporate interloqutors to update my contact information. I decided to take control of my mail system so that I would not have to go through that pain again. Later, when my son graduated from college, he and I made a project out of converting my scripts to Chef cookbooks. It was my son who chose the name "Cabal" for our project. More recently, I added Terraform code to manage the infrastructure.

With CabalMail, you can manage your own self-hosted email system as I do.

But CabalMail is a little different than traditional email.

## Subdomains

What's special about CabalMail is that it forces you to create new subdomains for each address. If we assume your mail domain is example.com, then CabalMail will *not* support addresses of the form foo@example.com. Rather, each address will be hosted at a subdomain of example.com, such as foo@bar.example.com.

By making it easy to create new addresses that point to a given inbox, you can (and should!) create new addresses for each person, company, etc., that needs to contact you. This approach is similar to the technique of ["plus-addressing" or "subaddressing"](https://tools.ietf.org/id/draft-newman-email-subaddr-01.html).

"So why not just use plus-addressing?" Good question. See the next section.

## Spam Handling

There isn't any. Nor is there a "Junk" folder (unless a user creates one). By not running Bayesian filters, machine learning algorithms, or other compute-intensive measures, you can operate your own email infrastructure with very small machines. Mine (which serves seven domains and four users) runs just fine on four t2.micros. My monthly AWS cost is less than $100. That's a lot of money in a world of free Gmail accounts, but if you value enhanced control and privacy, you may find it worthwhile as I do. And bear in mind that you can spread the cost among several users.

"But what if I start to get spam?" That's the best part. Simply go to the admin interface and revoke the address. This process does more than simply removing the address from your aliases; it also revokes any related DNS records. Because each address has a unique subdomain, the spam-sending relays can't even find your SMTP servers, so there is no need for your machines to accept the connection, evaluate the reputation of the sender, match the To: header against a list of supported addresses, apply spam filters, etc.

I almost never get spam. And when I do, I have a quick and easy solution.

Moreover, I can easily identify where the leak came from. When I start getting phishing email from a friend, I warn that friend that their account has been compromised. And while I'm at it, I give them a new address whith which to contact me. I can confidently identify which friend was affected, even if the phisher spoofs the From: address, as long as I have been careful to give each friend their own unique address at which to contact me.

You _could_ use a CabalMail system along with client-side spam filters, but I recommend against it. Client-side spam filters process mail only after your servers have received and processed it. This hides the spam from you at the cost of gradually (or not-so-gradually) increasing the load on your infrastructure. By making your spam visible, you can easily intercede to reduce load on your infrastructure and keep humming along with small machines. Also, you eliminate false positives; never again will important mail be misidentified as junk.

## Use Case

Admitedly, CabalMail serves a specialized use case, which is definitely not for everyone. With Google offering free mail with included spam filters, maybe CabalMail isn't for anyone. Maybe I'm the only cloud solution architect who doesn't like my inbox being scanned by anything I don't control. Maybe...

But I digress.

To get the benefits of a CabalMail system, you must get used to creating a new email address *each and every time you provide your contact information to a third party.* The administrative interface makes this easy, but it _is_ an additional step. One way to make this a bit less onerous is to pre-allocate a few random addresses in advance and keep them handy for the next time you need to fill out an online form.

In addition to being an extra step, it also requires an adjustment in the way one thinks about email. Often, when I give someone an address that they can use to contact me, and they see someting like "myname@yourname.example.com", they ask, "but, what's your *real* address." The notion that more than one email address can feed a single inbox is not hard to grasp, but scaling the idea to hudreds or thousands challenges the imagination. We tend to think of addresses and inboxes as having a one-to-one relationship, and the occasional alias is an exception. In fact, the true relationship is many-to-one, and no particular address is any more genuine or "real" than any other.

When I create a new address, I always leave it active until any of the following happen:

* An address gets abused.
* An address starts receiving mail from a different party than the one it was set up for.
* I wish to stop receiving mail from a party *and I have given them a fair opportunity to unsusbscribe me*.

I do not use this system to fool or defraud, and I urge you not to do so either. If you sign up for a service, either free or paid, the provider has a legitimate right to contact you regarding the provision of that service, and they have a right to expect that the information you give them about yourself is true and accurate. However, I do not believe that they have a legitimate expectation that you are giving them the same address that you give others.

# Use

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
            "Sid": "SidTheGreat",
            "Effect": "Allow",
            "Action": [
                "elasticfilesystem:DescribeBackupPolicy",
                "acm:DeleteCertificate",
                "elasticfilesystem:DeleteAccessPoint",
                "elasticfilesystem:PutAccountPreferences",
                "route53:GetHostedZone",
                "dynamodb:*",
                "elasticfilesystem:DescribeAccountPreferences",
                "autoscaling:*",
                "acm:RenewCertificate",
                "route53:ListHostedZonesByName",
                "elasticloadbalancing:DeleteLoadBalancer",
                "elasticloadbalancing:DescribeLoadBalancers",
                "secretsmanager:GetRandomPassword",
                "acm:RequestCertificate",
                "elasticfilesystem:ClientMount",
                "route53:ListResourceRecordSets",
                "acm:ImportCertificate",
                "elasticloadbalancing:ModifyTargetGroupAttributes",
                "elasticfilesystem:PutFileSystemPolicy",
                "elasticfilesystem:DeleteFileSystemPolicy",
                "elasticfilesystem:ModifyMountTargetSecurityGroups",
                "route53:CreateHostedZone",
                "elasticloadbalancing:CreateTargetGroup",
                "route53domains:UpdateDomainNameservers",
                "route53:ChangeResourceRecordSets",
                "acm:AddTagsToCertificate",
                "acm:ListTagsForCertificate",
                "iam:*",
                "elasticloadbalancing:DescribeLoadBalancerAttributes",
                "acm:DescribeCertificate",
                "elasticfilesystem:CreateMountTarget",
                "elasticloadbalancing:DescribeTargetGroupAttributes",
                "elasticloadbalancing:AddTags",
                "route53:ChangeTagsForResource",
                "ec2:*",
                "elasticfilesystem:ClientRootAccess",
                "elasticloadbalancing:ModifyLoadBalancerAttributes",
                "elasticfilesystem:DeleteFileSystem",
                "secretsmanager:ListSecrets",
                "elasticfilesystem:UntagResource",
                "route53:GetChange",
                "elasticfilesystem:CreateFileSystem",
                "elasticfilesystem:ListTagsForResource",
                "elasticfilesystem:ClientWrite",
                "elasticfilesystem:DeleteTags",
                "elasticloadbalancing:CreateListener",
                "elasticloadbalancing:DescribeListeners",
                "elasticfilesystem:DescribeLifecycleConfiguration",
                "elasticfilesystem:DescribeFileSystemPolicy",
                "elasticfilesystem:PutLifecycleConfiguration",
                "kms:DescribeKey",
                "route53:DeleteHostedZone",
                "elasticfilesystem:DescribeFileSystems",
                "elasticfilesystem:DeleteMountTarget",
                "elasticfilesystem:CreateAccessPoint",
                "kms:CreateGrant",
                "elasticfilesystem:DescribeMountTargets",
                "elasticloadbalancing:CreateLoadBalancer",
                "s3:*",
                "elasticfilesystem:Restore",
                "elasticloadbalancing:DescribeTags",
                "elasticfilesystem:DescribeAccessPoints",
                "elasticloadbalancing:*",
                "elasticloadbalancing:DeleteTargetGroup",
                "route53:ListTagsForResource",
                "elasticfilesystem:TagResource",
                "elasticfilesystem:CreateTags",
                "elasticfilesystem:DescribeTags",
                "elasticloadbalancing:DescribeTargetGroups",
                "elasticfilesystem:Backup",
                "elasticfilesystem:PutBackupPolicy",
                "sts:GetCallerIdentity",
                "elasticfilesystem:DescribeMountTargetSecurityGroups",
                "elasticfilesystem:UpdateFileSystem",
                "elasticloadbalancing:ModifyTargetGroup",
                "elasticloadbalancing:DeleteListener"
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

### Terraform
You must install Terraform or set up an account with [Terraform Cloud](https://app.terraform.io/signup/account). HashiCorp offers a free tier. These instructions assume you are using Terraform Cloud.

After signing up, perform the following steps:

1. [Create a worspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-create?in=terraform/cloud-get-started) of type version control workflow. Connect it to your cloned repository.
2. Using [terraform.tfvars.example](./terraform.tfvars.example) as a guide, [create variables in your workspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started).
3. [Create environment variables](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started) for `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` using the values you saved from the AWS section step 7. The secret access key should be designated "sensitive". Finally, create a third environment variable for `AWS_DEFAULT_REGION`. Set it to the same region you use for your primary infrastructure.

### Domain registration
You must register your desired domains (control and mail) with your chosen registrar. CabalMail requires exactly one control domain and at least one mail domain. Registration requires an email address. You can use a temporary account with any of the free providers for this address, and later, you can update the registration records with a self-hosted address once your hosting infrastructure is up and running.

### Fork this repository
Although you could connect Terraform Cloud directly to the original repository, it is safer to fork it. If you want to contribute to it, or extend it for your your own use, then forking is essential. Use the Github URL for your fork where called for in tfvars.

### Fork the cabal-cert repository
Fork the [cabal-cert repository](https://github.com/ccarr-cabal/cabal-cert) and follow the instructions in the README.

## Provisioning

1. Set up the prerequisites above.
2. Queue a plan in your Terraform Cloud workspace. When it finishes the plan phase, confirm and apply. If you are instead using Terraform locally, then create a terraform.tfvars file from the included example, and run Terraform apply:

        terraform init
        terraform plan
        terraform apply

## PTR Records
The output contains the IP addresses of each of your outgoing mail relays. In order to send mail reliably, you must [set up PTR records](https://blog.mailtrap.io/ptr-record/) for each outgoing SMTP server. Only AWS can do this for their EIPs, and there is no API, so the process cannot be automated. Fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits) for each outgoing SMTP sever. In addition to creating the necessary PTR records, it will also cause them to relax the rate limit on outgoing mail.