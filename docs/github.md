# Github

You must [sign up for a Github account](https://github.com/signup) if you don't already have one.

After signing up and logging in, [fork this repository](https://docs.github.com/en/get-started/quickstart/fork-a-repo). (Do not try to create infrastucture directly from the original repo.) Note the URL of the repository. You will need it later.

1. Log in to your Github account.
2. Navigate to the newly forked repository.
3. From the repository, navigate to Settings, and then Secrets. This should show any Actions secrets by default. If you see any other secrets settings, navigiate to Actions secrets.
4. Create four [secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets), one called AWS_ACCESS_KEY_ID, another called AWS_SECRET_ACCESS_KEY, and a third called AWS_REGION. Store the key ID and secret that you created in the [AWS setup](./aws.md) in step 10, and the region that you have chosen. The region should match what you specify in your [Terraform configuration](./terraform.md).

    | Secret                    | Required value                                                   |
    | ------------------------- | ---------------------------------------------------------------- |
    | AWS_ACCESS_KEY_ID         | Access key that you created in [AWS setup](./aws.md) in step 10. |
    | AWS_SECRET_ACCESS_KEY     | Access key that you created in [AWS setup](./aws.md) in step 10. |
    | AWS_REGION                | AWS region such as "us-east-1".                                  |
    | TF_TOKEN                  | See [Terraform setup](./terraform.md).                           |

5. [Set up a personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token). The scope should be repo and workflows. You will need this token when you set up Terraform.
6. Define the following environment variables:
    
    | Variable                  | Example value                                                    |
    | ------------------------- | ---------------------------------------------------------------- |
    | TF_VAR_AVAILABILITY_ZONES | [\"us-east-1a\",\"us-east-1b\"]                                  |
    | TF_VAR_AWS_REGION         | us-east-1                                                        |
    | TF_VAR_BACKUP             | true                                                             |
    | TF_VAR_CHEF_LICENSE       | accept                                                           |
    | TF_VAR_CIDR_BLOCK         | 10.0.0.0/16                                                      |
    | TF_VAR_CONTROL_DOMAIN     | example.net                                                      |
    | TF_VAR_EMAIL              | your_email@example.com                                           |
    | TF_VAR_ENVIRONMENT        | production                                                       |
    | TF_VAR_IMAP_SCALE         | { min = 1, max = 1, des = 1, size = \\"t3.small\\" }             |
    | TF_VAR_MAIL_DOMAINS       | [\\"example.com\\",\\"example.org\\"]                            |
    | TF_VAR_PROD               | true                                                             |
    | TF_VAR_REPO               | https://github.com/your-account/cabal-infra                      |
    | TF_VAR_SMTPIN_SCALE       | { min = 1, max = 1, des = 1, size = \\"t2.micro\\" }             |
    | TF_VAR_SMTPOUT_SCALE      | { min = 1, max = 1, des = 1, size = \\"t2.micro\\" }             |
    
    Note that quotation marks must be escaped with a single back-slash. (If you're reading this document in raw markdown, you'll see double-back-slashes.)

