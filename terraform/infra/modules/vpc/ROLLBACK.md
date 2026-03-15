# NAT Instance Rollback Instructions

If you need to roll back from NAT instances to NAT Gateways, follow these steps.

## Quick Rollback

1. In `terraform/infra/main.tf`, set `use_nat_instance = false` (or remove the variable entirely):

   ```hcl
   module "vpc" {
     source           = "./modules/vpc"
     use_nat_instance = false  # or remove this line
     # ... other variables
   }
   ```

2. Run terraform:

   ```bash
   cd terraform/infra
   terraform plan    # Review changes
   terraform apply   # Apply rollback
   ```

## What Happens During Rollback

Terraform will:
1. Create new NAT Gateways (one per AZ)
2. Associate EIPs with NAT Gateways (releases them from instances)
3. Update routes to point to NAT Gateways
4. Destroy NAT instances, security group, IAM role/profile

## Expected Downtime

**2-5 minutes** of outbound connectivity loss from private subnets while:
- EIPs are reassociated
- Routes are updated
- NAT Gateways become available

## Verification After Rollback

1. Check NAT Gateway status in AWS Console or CLI:
   ```bash
   aws ec2 describe-nat-gateways --filter "Name=state,Values=available"
   ```

2. Test outbound connectivity from a private subnet instance:
   ```bash
   curl https://api.ipify.org
   ```
   Should return one of your NAT EIPs.

3. Verify reverse DNS (for SMTP):
   ```bash
   dig -x <EIP-address>
   ```
   Should return `smtp.<your-control-domain>`.
