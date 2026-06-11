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

The developers have striven to make provisioning as automated as possible. However, there are some necessarily manual steps. Several of these steps are discussed above under [Prerequisites](#Prerequisites), and others are discussed below under [Post-Automation Steps](#PostAutomation). However, one step unavoidably must be attended to during the initial provisioning. This is why the terraform directory has been subdivided into two subdirectories: The first performs the initial automation, and the second all the rest. The order is dns first and infra second. The overwhelming majority of resources are created by infra. In between, you must update the domain registration for your control domain. Both stacks are deployed by the same "Build and Deploy Infrastructure" workflow; see [Terraform setup](./terraform.md) for how it works.

1. Set up the [prerequisites](#Prerequisites) above. For this first run, make sure you have added required reviewers to the `gate-*` environments ([GitHub setup](./github.md)) -- the pause at the approval gates is what lets you update your domain registration between the dns and infra stages.

2. Kick off the "Build and Deploy Infrastructure" workflow with the bootstrap stage forced. WARNING: Performing this step will result in charges on your credit card from Amazon Web Services.

    1. Navigate in your browser to your repository in GitHub.
    2. Navigate to the Actions tab.
    3. Navigate to "Build and Deploy Infrastructure".
    4. Pull down the "Run workflow" menu, check "Force run of the bootstrap (terraform/dns) stage", and click the green "Run workflow" button.
    5. Approve the bootstrap stage's gate when the run pauses there, and wait for the bootstrap apply to finish.
    6. Note the output of the bootstrap apply. You will need it for step 3. The run will continue into the main (terraform/infra) stage and pause at a second approval gate. Leave it waiting there until step 5.

3. The output from the bootstrap apply in step 2 will include name servers. [Update the domain registration](./registrar.md) for your control domain with these name servers. *Before approving the main stage, make sure this change is complete*.

4. **WHOA**. Verify that steps 2 and 3 were successful. Do not proceed to step 5 otherwise.

5. Approve the main stage's gate on the workflow run from step 2. (If the run is no longer waiting -- approval gates time out after 30 days, and without required reviewers the run proceeds on its own -- run "Build and Deploy Infrastructure" again from the Actions tab, this time without the bootstrap checkbox.) Note the output at the end of apply/apply-terraform. You will need it for the [post-automation tasks](#PostAutomation) below.

6. Kick off the "Build and Deploy Application" workflow.

    1. Navigate in your browser to your repository in GitHub.
    2. Navigate to the Actions tab.
    3. Navigate to "Build and Deploy Application".
    4. Pull down the "Run workflow" menu.
    5. Leave the area input at `all` and click on the green "Run workflow" button.

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

## SMS verification (Required for phone verification)

Cognito sends verification SMS through AWS SNS. New AWS accounts are placed in the SNS SMS sandbox, which restricts delivery to manually verified phone numbers only. For production use, you must request production access.

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

Cabalmail ships with an optional monitoring stack (Uptime Kuma + self-hosted ntfy + an `alert_sink` Lambda that fans out to Pushover and ntfy push notifications) that is disabled by default. To turn it on, set `TF_VAR_MONITORING=true` in your GitHub Actions environment, then follow [the monitoring setup guide](./monitoring.md) to create your Pushover account, seed the SSM secrets, bootstrap the ntfy admin user, create the Kuma admin user, wire the webhook provider, and add the Phase 1 monitors. The guide also covers secret rotation and cleanly disabling the stack.

## Port 25 Block (What to do with the `relay_ips` output)

The output contains the IP address of each of your outgoing mail relays. (More specifically, it's the elastic IP addresses used for egress on the NAT instances.) In order to send mail reliably, you must get AWS to allow outbound traffic on port 25. There is no API for this, so the process cannot be automated. Instead, you must fill out [this form](https://console.aws.amazon.com/support/contacts?#/rdns-limits).

## NAT

All private-subnet egress (outbound mail and every AWS service call) flows through the VPC's NAT, and there are no VPC endpoints, so NAT health is load-bearing for the whole data plane. For the two NAT modes (EC2 instances or NAT Gateways), how to bring either up in a new environment, and how to diagnose an egress outage, see [NAT and private-subnet egress](./nat.md).