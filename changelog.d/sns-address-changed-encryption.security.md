- The `cabal-address-changed` SNS topic is now encrypted at rest with the
  AWS-managed `aws/sns` key. The new/revoke Lambda (the only publisher) is
  granted `kms:GenerateDataKey`/`Decrypt` scoped via `kms:ViaService=sns`, so
  publishing keeps working.
