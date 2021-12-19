resource "aws_ssm_document" "run_chef_now" {
  name          = "cabal_chef_document"
  document_type = "Command"
  content = <<DOC
  {
    "schemaVersion": "2.2",
    "description": "Run chef-solo",
    "parameters": {
      "commands": {
        "type": "String",
        "description": "Run chef-solo on all machines",
        "default": "chef-solo -c /etc/chef/solo.rb -z -j /var/lib/chef/attributes/node.json"
      }
    },
    "mainSteps": [
      {
        "action": "aws:runShellScript",
        "name": "runShellScript",
        "inputs": {
          "timeoutSeconds": "300",
          "runCommand": [
            "{{ commands }}"
          ]
        }
      }
    ]
  }
DOC
}