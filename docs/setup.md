# Prerequisites<a name="Prerequisites"></a>

Before using this repo, you must set up an appropriate environment.

## Amazon Web Services Account

[Set up an Amazon Web Services Account](./aws.md).

## Github

[Set up a Github repository](./github.md).

## Terraform

[Set up Terraform](./terraform.md).

## Domain registration

NOTE: Domain registration is not free. You will need to provide a form of payment.

You must register your desired domains (control and mail) with your chosen registrar. Cabalmail requires exactly one control domain and at least one mail domain. Registration requires an email address. You can use a temporary email account with any of the free providers for this address, and later, you can update the registration records with a self-hosted address once your hosting infrastructure is up and running.

The control domain is for infrastructure, not for email addresses. If you like to send mail from example.com, you might use example.net as your control domain. If so, then you would retrieve your mail from imap.example.net, send mail to smtp-out.example.net, and manage your addresses at admin.example.net.

If you don't have a preference for registrars, you can use the [Route 53 Registrar service](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html) in the AWS account you created above.

# Provisioning

The developers have striven to make provisioning as automated as possible. However, there are some manual steps. Several of these steps are discussed above under [Prerequisites](#Prerequisites), and others are discussed below under [Post-Autonation Steps](#PostAutomation). However, one step unavoidably must be attended to during the provsioning. This is why the terraform directoy has been subdivided into two subdirectories: The first performs the initial automation, and the second all the rest. The order is dns first and infra second. The overwhelming majority of resources are created by infra. In between, you will be instructed to update your domain registrations and add a secret to your Github repository settings.

1. Set up the [prerequisites](#Prerequisites) above.

2. Run the terraform/dns workspace. WARNING: Performing this step will result in charges on your credit card from Amazon Web Services.

    1. Queue a plan in your Terraform Cloud terraform/dns workspace.
    2. When it finishes the plan phase, confirm and apply.
    3. The output will include name servers. [Update the domain registration](./registrar.md) for your control domain with these name servers. *Before proceeding to the terraform/infa workspace, make sure this change is complete*.
    4. The output will also include the name of an S3 bucket that you must store in the [Secrets settings](https://docs.github.com/en/actions/security-guides/encrypted-secrets) of your Github repository:

        1. Log in to your Github account.
        2. Navigate to the newly forked repository.
        3. From the repository, navigate to Settings, and then Secrets. This should show any Actions secrets by default. If you see any other secrets settings, navigiate to Actions secrets.
        4. Click "New repository secret", and enter "AWS_S3_BUCKET" for the key and the value specifed in the Terraform output for the value.

3. Run the terraform/infra workspace. WARNING: Performing this step will result in charges on your credit card from Amazon Web Services.

    1. Queue a plan in your Terraform Cloud terraform/infra workspace.
    2. When it finishes the plan phase, confirm and apply.

4. Perform the [post-autonation tasks](#PostAutomation) below.

# Reprovisioning

You can rerun the provisioning steps any time. If you have not changed anything in the code or in the variables, the operation should be safe. If either of the above Terraform workspaces fail to provision, running them again may be sufficient.

Theoretically, it should also be safe to change any of the variables except the AWS region. As long as the new values are sensible, Terraform should reestablish the infrastructure with the new parameters, and your mail should still be there. But we do not guarantee this, and we strongly recommend that you [perform backups](./operations.md) first.

# Post-Automation Steps<a name="PostAutomation"></a>

Look at the output from Terraform! If you are using Terraform Cloud, it is not shown by default; you have to expand it in the UI.

It should look something like this:

```json
{
  "IMPORTANT": [
    "You must get permission from AWS to relay mail through the below IP addresses. See the section on Port 25 in docs/setup.md.",
    "You must update your domain registrations with the name servers from the below domains. See the section on Nameservers in docs/setup.md"
  ],
  "domains": [
    {
      "domain": "example.com",
      "name_servers": [
        "ns-1111.awsdns-55.net",
        "ns-2222.awsdns-66.org",
        "ns-3333.awsdns-77.co.uk",
        "ns-4444.awsdns-88.com"
      ],
      "zone_id": "Z0431XXXXXXXXXXXXXXX0"
    },
    {
      "domain": "example.org",
      "name_servers": [
        "ns-1111.awsdns-55.org",
        "ns-2222.awsdns-66.com",
        "ns-3333.awsdns-77.net",
        "ns-4444.awsdns-88.co.uk"
      ],
      "zone_id": "Z0431XXXXXXXXXXXXXXX1"
    }
  ],
  "relay_ips": {
    "addresses": [
      "192.168.0.1"
    ],
    "domain": "smtp.example.net"
}
```

## Nameservers (What to do with the `domains` output)

The output contains the nameservers that AWS assigned to your mail domains. To work at all, you must [update your domain registrations with these nameservers](./registrar.md).

## Port 25 Block (What to do with the `relay_ips` output)

The output contains the IP address of each of your outgoing mail relays. (More specifically, it's the elastic IP addresses used for egress on the NAT gateway.) In order to send mail reliably, you must get AWS to allow outbound traffic on port 25. There is no API for this, so the process cannot be automated. Instead, you must fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).