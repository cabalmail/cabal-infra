# Prerequisites

Before using this repo, you must set up an appropriate environment.

## Fork this repository

Although you could connect Terraform Cloud directly to the original repository, it is safer to fork it. If you want to contribute to it, or extend it for your your own use, then forking is essential. Use the Github URL for your fork where called for in tfvars.

## AWS Account

[Set up an AWS Account](./aws.md).

## Terraform

[Set up Terraform](./terraform.md).

## Domain registration

You must register your desired domains (control and mail) with your chosen registrar. Cabalmail requires exactly one control domain and at least one mail domain. Registration requires an email address. You can use a temporary account with any of the free providers for this address, and later, you can update the registration records with a self-hosted address once your hosting infrastructure is up and running.

The control domain is for infrastructure, not for email addresses. If you like to send mail from example.com, you might use example.net as your control domain. If so, then you would retrieve your mail from imap.example.net, send mail to smtp-out.example.net, and manage your addresses at admin.example.net.

# Provisioning

1. Set up the prerequisites above.

2. Run the terraform/dns stack.

    1. Queue a plan in your Terraform Cloud terraform/dns workspace.
    2. When it finishes the plan phase, confirm and apply.
    3. The output will include name servers. [Update the domain registration](./registrar.md) for your control domain with these name servers. Before proceeding to the next step, make sure this change is complete.
    4. The output will also include a zone ID. Update the `zone_id` variable for the terraform/infra workspace with this ID.

3. Run the terraform/cert workspace.

    1. Queue a plan in your Terraform Cloud terraform/cert workspace.
    2. When it finishes the plan phase, confirm and apply.

4. Run the terraform/infra workspace.

    1. Queue a plan in your Terraform Cloud terraform/infra workspace.
    2. When it finishes the plan phase, confirm and apply.

# Reprovisioning

You can rerun the provisioning steps any time. If you have not changed anything in the code or in the variables, the operation should be safe. At worst, it will update the AMI on which the machines run, resulting in new machines being launched, but no mail will be lost, with the rare exception of mail that had been queued for redelivery following a transitory error.

Theoretically, it should also be safe to change any of the variables except the AWS region. As long as the new values are sensible, Terraform should reestablish the infrastructure with the new parameters, and your mail should still be there. But we do not guarantee this, and we strongly recommend that you perform backups first.

# Post-Automation Steps

Look at the output from Terraform! If you are using Terraform Cloud, it is not shown by default; you have to expand it in the UI.

It should look something like this:

```json
{
  "IMPORTANT": [
    "You must get permission from AWS to relay mail through the below IP addresses. See the section on PTR records in README.md.",
    "You must update your domain registrations with the name servers from the below domains. See the section on Name Servers in README.md"
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

## Name Servers (What to do with the `domains` output)

The output contains the name servers that AWS assigned to your mail domains. To work at all, you must [update your domain registrations with these name servers](./registrar.md).

## Port 25 Block (What to do with the `relay_ips` output)

The output contains the IP address of each of your outgoing mail relays. (More specifically, it's the elastic IP addresses used for egress on the NAT gateway.) In order to send mail reliably, you must get AWS to allow outbound traffic on port 25. There is no API for this, so the process cannot be automated. Instead, you must fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).