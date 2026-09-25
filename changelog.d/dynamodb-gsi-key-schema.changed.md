- **DynamoDB index keys declared as `key_schema`.** The four RSS tables'
  eight `global_secondary_index` blocks moved off the `hash_key` /
  `range_key` arguments, which the AWS provider deprecated in favour of
  nested `key_schema` blocks, and the `aws_s3_object` lifecycle blocks in
  the user-pool module stopped listing the provider-decided `version_id`
  in `ignore_changes`. Together those were the 20 warnings every infra
  plan and validate emitted (#1711); the declared keys, and the indexes
  themselves, are unchanged.
