# Recommended Steps for Setting Up Terraform

You must install Terraform or set up an account with [Terraform Cloud](https://app.terraform.io/signup/account). HashiCorp offers a free tier. These instructions assume you are using Terraform Cloud.

After signing up, perform the following steps:

1. [Create a workspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-create?in=terraform/cloud-get-started) of type version control workflow called "infra". Connect it to your forked repository. While creating the workspace, expand the "Advanced options" area and fill out the fields with these values:

    |Field                      |Value                                                        |
    |---------------------------|-------------------------------------------------------------|
    |Description                |Create Infrastructure and Application for Cabalmail          |
    |Terraform Working Directory|terraform/infra                                              |
    |Automatic Run Triggering   |Only trigger runs when the files in the spcified paths change|
    |- Paths                    |terraform/infra, chef                                        |
    |VCS branch                 |default                                                      |
    |Include submodules on clone|Unchecked                                                    |

2. Using [terraform.tfvars.example](./terraform.tfvars.example) as a guide, [create variables in your workspace](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started).

3. [Create environment variables](https://learn.hashicorp.com/tutorials/terraform/cloud-workspace-configure?in=terraform/cloud-get-started) for `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` using the values you saved from [the AWS section step 7](./aws.md). The secret access key should be designated "sensitive". (Don't forget to rotate this key regularly!) Finally, create a third environment variable for `AWS_DEFAULT_REGION`. Set it to the same region you use for your infrastructure.

4. Repeat steps 1 through 3, for another workspace called "dns" using these values:

    |Field                      |Value                                                        |
    |---------------------------|-------------------------------------------------------------|
    |Description                |Create DNS Zone for Cabalmail control domain                 |
    |Terraform Working Directory|terraform/dns                                                |
    |Automatic Run Triggering   |Only trigger runs when the files in the spcified paths change|
    |- Paths                    |terraform/dns                                                |
    |VCS branch                 |default                                                      |
    |Include submodules on clone|Unchecked                                                    |
