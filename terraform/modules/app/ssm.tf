resource "aws_ssm_document" "cabal_document" {
  for_each = toset( ["imap", "smtp-in", "smtp-out"] )
  name          = "cabal_${each.key}_document"
  document_type = "Command"
  content = <<DOC
  {
    "schemaVersion": "1.2",
    "description": "Run chef-solo",
    "parameters": {

    },
    "runtimeConfig": {
      "aws:runShellScript": {
        "properties": [
          {
            "id": "0.aws:runShellScript",
            "runCommand": ["chef-solo -c /etc/chef/solo.rb -z -o 'recipe[cabal::${each.key}]' -j /var/lib/chef/attributes/${each.key}.json"]
          }
        ]
      }
    }
  }
DOC
}