# cabal-infra
Creates AWS infrastructure for a CabalMail system.

# About
CabalMail is a suite of infrastructure code ([Terraform](https://www.terraform.io/)) and configuration management code ([Chef Infra](https://www.chef.io/)) that together create the following system components:
- IMAP hosts
- SMTP relay hosts
- SMTP submission hosts
- Administrative interface for managing addresses
- Other supporting infrastructure

CabalMail grew out of a bunch of scripts and configuration files that I originally set up when I wanted to take control of my own email hosting. Some time in the late 1990s, I started getting spammed at a third-party address that I had used for years. Spam filters were unreliable at the time, and my inbox quickly became unusable. I reluctantly went through the pain of contacting all my friends, family, and corporate interloqutors to update my contact information. I decided to take control of my mail system so that I would not have to go through that pain again. Later, when my son graduated from college, he and I made a project out of converting my scripts to Chef cookbooks. It was my son who chose the name "Cabal" for our project.

With CabalMail, you can manage your own self-hosted email system as I do.

But CabalMail is a little different than traditional email.

## Subdomains

What's special about CabalMail is that it forces you to create new subdomains for each address. If we assume your mail domain is example.com, then CabalMail will NOT support addresses of the form foo@example.com. Rather, each address will be hosted at a subdomain of example.com, such as foo@bar.example.com. This approach is similar to the technique of ["plus-addressing" or "subaddressing"](https://tools.ietf.org/id/draft-newman-email-subaddr-01.html).

"So why not just use plus-addressing?" Good question. See the next section.

## Spam Handling

There isn't any. Nor is there a "Junk" folder. By not running Bayesian filters, machine learning algorithms, or other compute-intensive measures, you can operate your own email infrastructure with very small machines. Mine (which serves seven domains and four users) runs just fine on four t2.micros. My monthly AWS cost is less than $100. (That's a lot of money in a world of free Gmail accounts, but if you value enhanced control and privacy, you may find it worthwhile as I do. And bear in mind that you can spread the cost among several users.)

"But what if I start to get spam?" That's the best part. Simply go to the admin interface and revoke the address. Because each address has a unique subdomain, the spam-sending relays can't even find your SMTP servers, so there is no need for your machines to accept the connection, evaluate the reputation of the sender, match the To: header against a list of supported addresses, etc.

I almost never get spam. And when I do, I have a quick and easy solution.

You _could_ use a CabalMail system along with client-side filters, but I recommend against it. By making your spam visible, you can easily intercede to reduce load on your infrastructure and keep humming along with small machines. Also, you eliminate false positives; never again will important mail be misidentified as junk. And, you can easily tell who shared and/or abused your address.

## Use Case

Admitedly, CabalMail is a special use case, which is definitely not be for everyone. To get the benefits of a CabalMail system, you must get used to creating a new email address *each and every time you provide your contact information to a third party.* The administrative interface makes this easy, but it _is_ an additional step. One way to make this a bit less onerous is to pre-allocate a few random addresses in advance and keep them handy for the next time you need to fill out an online form.

(I assume this practice also prevents companies and governments from tracking you across different accounts, though this may not work so well if lots of people start using it.)

When I create a new address, I always leave it active until any of the following happen:
- An address gets abused.
- An address starts receiving mail from a different party than the one it was set up for.
- I wish to stop receiving mail from a party *and I have given them a fair opportunity to unsusbscrie me*.

I do not use this system to fool or defraud, and I urge you not to do so either. If you sign up for a service, either free or paid, the provider has a legitimate right to contact you regarding the provision of that service. However, I do not believe that they have a legitimate expectation that you are giving them the same address that you give others.

# Use

## Variables

### create_secondary
Whether to create infrastructure in a second region. Recommended for prod.

type: bool
default: false

### aws_primary_region
AWS region in which to provision primary infrastructure. Must be a valid AWS region

type: string
default: us-west-1

### aws_secondary_region
AWS region in which to provision secondary infrastructure. Must be a vaild AWS region.

type: string
default: us-east-1

### primary_cidr_block
CIDR block for the VPC in the primary region. Must be in valid CIDR format.

type: string
Required

### secondary_cidr_block
CIDR block for the VPC in the secondary region. Must be in valid CIDR format.

type: string
Required

### az_count
Number of Availability Zones to use. 3 recommended for prod. Must be an integer greater than zero and less than or equal to the maximum number of availability zones in your chosen regions.

type: number
default: 1

### repo
This repository. Used for resource tagging. Should be a valid git URL.

type: string
default: "https://github.com/ccarr-cabal/cabal-infra/tree/main"

## Prerequisites
Before using this repo, you must set up an appropriate environment.

### AWS Account
You must [sign up for an AWS account](https://portal.aws.amazon.com/billing/signup#/start).

TODO: Document the minimum IAM permissions required.

### Terraform
You must install Terraform or set up an account with [Terraform Cloud](https://app.terraform.io/signup/account). HashiCorp offers a free tier.

### Chef Infra Server
You must have an organization set up on [Chef Infra Server](https://www.chef.io/products/chef-infra). Chef offers a [managed service](https://manage.chef.io/signup) with a free tier. If you want to stay within AWS, you could try OpsWorks. And you must have [Chef-Workstation](https://downloads.chef.io/tools/workstation) configured to administer your Chef organization.

### Domain registration
You must register your desired domains (control and mail) with your chosen registrar. CabalMail requires exactly one control domain and at least one mail domain.

## Provisioning

1. Set up the prerequisites above.
2. Clone this repository.
3. Upload the cookbooks to your Chef Infra Server organization using knife (which ships with Chef-Workstation).
    cd cookbooks
    knife cookbook upload imap -o ./
    knife cookbook upload smtp -o ./
4. Create a tfvars file to supply appropriate values for the variables above.
5. Run Terraform apply
    terraform init
    terraform apply

## Manual Steps
After running terraform apply, you must complete the following steps manually.

### Name servers
The output contains name servers for each of the domains (control and mail) you specify. You must update your whois record with your domain registrar with this information.

### PTR Records
In order to send mail reliably, you must [set up PTR records](https://blog.mailtrap.io/ptr-record/) for each outgoing SMTP server. Only AWS can do this for their EIPs, and there is no API, so the process cannot be automated. Fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits) for each outgoing SMTP sever. In addition to creating the necessary PTR records, it will also cause them to relax the rate limit on outgoing mail.