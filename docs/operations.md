# Backups

Mail is stored in AWS Elastic File System, and address data is stored in DynamoDB. AWS EFS is designed to achieve [99.999999999% (eleven nines) durability](https://aws.amazon.com/efs/faq/#Data_protection_.26_availability). AWS does not publish a durability rating for DynamoDB, but they [do say](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html#ddb_highavailability) that they replicate DynamoDB tables across multiple availability zones for "high durability". But however much you may trust AWS's assurances, they cannot protect you from users deliberately deleting mail and then changing their mind.

If you want Cabalmail to establish backups for you, set the `backup` input variable to `true`. Doing this may prevent clean destruction of a Cabalmail stack. If you would prefer to roll your own backups, AWS publishes instructions for backing up [EFS](https://docs.aws.amazon.com/efs/latest/ug/efs-backup-solutions.html) and [DynamoDB](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Backup.Tutorial.html).

Cabalmail sets `prevent_destroy` on the backup vault, so enabling Cabalmail backups will prevent a complete clean up by `terraform destroy`.

# Everyday Use

See the [User Manual](./user_manual.md) for instructions on using the included application for creating and revoking email addresses, and for managing user access.