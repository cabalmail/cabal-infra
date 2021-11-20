# Backups

The code in this repository *does not* establish any form of backup. Mail is stored in AWS Elastic File System, and address data is stored in DynamoDB. AWS EFS is designed to achieve [99.999999999% (eleven nines) durability](https://aws.amazon.com/efs/faq/#Data_protection_.26_availability). AWS does not publish a durability rating for DynamoDB, but they [do say](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Introduction.html#ddb_highavailability) that they replicate DynamoDB tables across multiple availability zones for "high durability". But however much you may trust AWS's assurances, they cannot protect you from users deliberately deleting mail and then changing their mind.

You are responsible for your own backups.

# Everyday Use

See the [User Manual](./user_manual.md) for instructions on using the included application for creating and revoking email addresses.