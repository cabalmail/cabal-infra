locals {
  lambdas = {
    list_mailboxes   = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 128
    },
    list_messages    = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 128
    },
    list_envelopes   = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 128
    },
    fetch_message    = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 1024
    },
    list_attachments = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 1024
    },
    fetch_attachment = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 1024
    },
    fetch_inline_attachment = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
      memory  = 1024
    },
    list             = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "GET"
      memory  = 128
    },
    new              = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "POST"
      memory  = 128
    },
    revoke           = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "DELETE"
      memory  = 128
    }
  }
}