locals {
  lambdas = {
    list_folders       = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 60
    },
    list_messages      = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 15
    },
    list_envelopes     = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 3600
    },
    fetch_message      = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    fetch_bimi         = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    list_attachments   = {
      runtime   = "python3.9"
      type      = "python"
      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 3600
    },
    fetch_attachment   = {
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
    set_flag           = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    new_folder         = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    delete_folder      = {
      runtime   = "python3.9"
      type      = "python"
      method    = "DELETE"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    subscribe_folder   = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    unsubscribe_folder = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    move_messages      = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    send               = {
      runtime   = "python3.9"
      type      = "python"
      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    list               = {
      runtime   = "nodejs20.x"
      type      = "nodejs"
      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 60
    },
    new                = {
      runtime   = "nodejs20.x"
      type      = "nodejs"
      method    = "POST"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    revoke             = {
      runtime   = "nodejs20.x"
      type      = "nodejs"
      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    }
  }
}
