locals {
  lambda_layers = {
    python = {
      runtime   = "python3.9"
    }
  }
  lambdas = {
    list_folders     = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 60
    },
    list_messages    = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 15
    },
    list_envelopes   = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 3600
    },
    fetch_message    = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    list_attachments = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    fetch_attachment = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    fetch_inline_image = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    list             = {
      runtime   = "nodejs14.x"
      type      = "node"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 60
    },
    new              = {
      runtime   = "nodejs14.x"
      type      = "node"
      method    = "POST"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    revoke           = {
      runtime   = "nodejs14.x"
      type      = "node"
      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    }
  }
}