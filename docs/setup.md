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

The developers have striven to make provisioning as automated as possible. However, there are some necessarily manual steps. Several of these steps are discussed above under [Prerequisites](#Prerequisites), and others are discussed below under [Post-Automation Steps](#PostAutomation). However, one step unavoidably must be attended to during the initial provsioning. This is why the terraform directory has been subdivided into two subdirectories: The first performs the initial automation, and the second all the rest. The order is dns first and infra second. The overwhelming majority of resources are created by infra. In between, you will be instructed to update your domain registrations and add a secret to your Github repository settings.

1. Set up the [prerequisites](#Prerequisites) above.

2. Run the terraform/dns workspace. WARNING: Performing this step will result in charges on your credit card from Amazon Web Services.

    1. Queue a plan in your Terraform Cloud terraform/dns workspace.
    2. When it finishes the plan phase, confirm and apply.
    3. Note the output. You will need it for step 3.

3. The output from the Terraform run in step 2 will include name servers. [Update the domain registration](./registrar.md) for your control domain with these name servers. *Before proceeding to the terraform/infa workspace, make sure this change is complete*.

4. **WHOA**. Verify that steps 2 and 3 were successful. Do not proceed to step 5 otherwise.

5. Kick off the "Build and Deploy Terraform Infrastructure" workflow.

    1. Navigate in your browser to your repository in GitHub.
    2. Navigate to the Actions tab.
    3. Navigate to "Build and Deploy Terraform Infrastructure".
    4. Pull down the "Run workflow" menu.
    5. Click on the green "Run workflow" button.
    6. Note the output at the end of apply/apply-terraform. You will need it for the [post-automation tasks](#PostAutomation) below.

6. Kick off the "Build and Push Docker Images" workflow

    1. Navigate in your browser to your repository in GitHub.
    2. Navigate to the Actions tab.
    3. Navigate to "Build and Push Docker Images".
    4. Pull down the "Run workflow" menu.
    5. Click on the green "Run workflow" button.

7. Perform the [post-automation tasks](#PostAutomation) below.

# Reprovisioning

Theoretically, it should also be safe to change any of the variables except the AWS region. As long as the new values are sensible, Terraform should reestablish the infrastructure with the new parameters, and your mail should still be there. But we do not guarantee this, and we strongly recommend that you [perform backups](./operations.md) first.

# Post-Automation Steps<a name="PostAutomation"></a>

Look at the output from Terraform at the end of apply/apply-terraform in GitHub Actions. It should look something like this:

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

## SMS Sandbox (Required for phone verification)

New AWS accounts are placed in the SNS SMS sandbox, which restricts SMS delivery to manually verified phone numbers only. For production use, you must request production access so that Cognito can send verification codes to any phone number.

1. Open the [Amazon SNS console](https://console.aws.amazon.com/sns/v3/home#/mobile/text-messaging) in your production account.
2. In the left navigation, choose **Text messaging (SMS)**.
3. In the **Account information** section, choose **Exit SMS sandbox**.
4. Fill out the support case:
   - **Limit type**: SNS Text Messaging
   - **Use case description**: Describe that you use Cognito for user phone verification and password recovery.
   - **Monthly SMS spend limit**: Request an appropriate limit (the default is $1.00/month; typical small deployments need $5-10).
   - **Message type**: Transactional
5. AWS typically processes the request within 1-2 business days.

Until production access is granted, you can test SMS by adding destination phone numbers to the sandbox via the SNS console under **Text messaging > Sandbox destination phone numbers**.

## Monitoring & Alerting (Optional)

Cabalmail ships with an optional monitoring stack (Uptime Kuma + SMS alerting via an `alert_sms` Lambda) that is disabled by default. To turn it on, set `TF_VAR_MONITORING=true` and populate `TF_VAR_ON_CALL_PHONE_NUMBERS` in your GitHub Actions environment, then follow [the monitoring setup guide](./monitoring.md) to confirm SMS subscriptions, create the Kuma admin user, wire the webhook provider, and add the Phase 1 monitors. The guide also covers shared-secret rotation and cleanly disabling the stack.

## Port 25 Block (What to do with the `relay_ips` output)

The output contains the IP address of each of your outgoing mail relays. (More specifically, it's the elastic IP addresses used for egress on the NAT gateway.) In order to send mail reliably, you must get AWS to allow outbound traffic on port 25. There is no API for this, so the process cannot be automated. Instead, you must fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).