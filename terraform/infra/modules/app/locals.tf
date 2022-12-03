locals {
  lambdas = {
    list_mailboxes   = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    list_messages    = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    list_envelopes   = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    fetch_message    = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    list_attachments = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    list_attachments = {
      runtime = "python3.9"
      type    = "python"
      method  = "POST"
    },
    list             = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "GET"
    },
    new              = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "POST"
    },
    revoke           = {
      runtime = "nodejs14.x"
      type    = "node"
      method  = "DELETE"
    }
  }
}