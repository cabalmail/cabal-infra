# Backups

Mail is stored in AWS Elastic File System, and address data is stored in DynamoDB. AWS EFS is designed to achieve [99.999999999% (eleven nines) durability](https://aws.amazon.com/efs/faq/#Data_protection_.26_availability). AWS does not publish a durability rating for DynamoDB, but they [do say](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html#ddb_highavailability) that they replicate DynamoDB tables across multiple availability zones for "high durability". But however much you may trust AWS's assurances, they cannot protect you from users deliberately deleting mail and then changing their mind.

If you want Cabalmail to establish backups for you, set the `backup` input variable to `true`. Doing this may prevent clean destruction of a Cabalmail stack. If you would prefer to roll your own backups, AWS publishes instructions for backing up [EFS](https://docs.aws.amazon.com/efs/latest/ug/efs-backup-solutions.html) and [DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Backup.Tutorial.html).

Cabalmail sets `prevent_destroy` on the backup vault, so enabling Cabalmail backups will prevent a complete clean up by `terraform destroy`.

# Everyday Use

See the [User Manual](./user_manual.md) for instructions on using the included application for creating and revoking email addresses, and for managing user access.

You _could_ use a Cabalmail system along with client-side spam filters, but I recommend against it. Client-side spam filters process mail only after your servers have received and processed it. This hides the spam from you at the cost of gradually (or not-so-gradually) increasing the load on your infrastructure. By making your spam visible, you can easily intercede to reduce load on your infrastructure and keep humming along with small machines. Also, you eliminate false positives; never again will important mail be misidentified as junk.

You also _could_ create a single address on a Cabalmail system and just give that out to everyone like a normal address. But if you do, get ready to take a fresh look at those client-side spam filters.