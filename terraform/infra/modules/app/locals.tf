locals {
  supported_lambdas = {
    list_folders = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 60
    },
    folder_status = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 15
    },
    list_messages = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = true
      cache_ttl = 15
    },
    search_envelopes = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_envelopes = {
      runtime = "python3.13"

      method = "GET"
      memory = 128
      cache  = true
      # Personalised response: not cached at the gateway, so a revoked token
      # cannot read another caller's cached private data within the TTL window.
      cache_ttl = 0
    },
    fetch_message = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 0 # personalised: not gateway-cached (see list_envelopes)
    },
    fetch_bimi = {
      runtime = "python3.13"

      method = "GET"
      memory = 1024
      cache  = true
      # Non-personalised: keyed by sender domain, identical for every caller,
      # so a shared gateway cache is safe and worthwhile.
      cache_ttl = 3600
    },
    list_attachments = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 0 # personalised: not gateway-cached (see list_envelopes)
    },
    fetch_attachment = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 0 # personalised: not gateway-cached (see list_envelopes)
    },
    fetch_inline_image = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 1024
      cache     = true
      cache_ttl = 0 # personalised: not gateway-cached (see list_envelopes)
    },
    set_flag = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    new_folder = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    delete_folder = {
      runtime = "python3.13"

      method    = "DELETE"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    subscribe_folder = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    unsubscribe_folder = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    move_messages = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = true
      cache_ttl = 0
    },
    purge_messages = {
      runtime = "python3.13"

      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    empty_trash = {
      runtime = "python3.13"

      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    send = {
      runtime = "python3.13"

      method = "PUT"
      # Bumped from 128 MB so the function can stage and MIME-encode
      # attachments fetched from S3 (the /upload_url path) without
      # tripping out-of-memory at the server-side cap of 25 MB.
      memory    = 512
      cache     = true
      cache_ttl = 0
    },
    save_draft = {
      runtime = "python3.13"

      method = "PUT"
      # Same compose pipeline as /send (attachments staged from S3 and
      # MIME-encoded in memory), so it needs the same headroom.
      memory    = 512
      cache     = false
      cache_ttl = 0
    },
    upload_url = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    new = {
      runtime = "python3.13"

      method    = "POST"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    revoke = {
      runtime = "python3.13"

      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    set_favorite = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_users = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    confirm_user = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    disable_user = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    enable_user = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    delete_user = {
      runtime = "python3.13"

      method    = "DELETE"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_dmarc_reports = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    check_dns_record = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    repair_dns_record = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_addresses_admin = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    assign_address = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    unassign_address = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    new_address_admin = {
      runtime = "python3.13"

      method    = "POST"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    get_preferences = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    set_preferences = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_user_domain_access = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    set_user_domain_access = {
      runtime = "python3.13"

      method    = "PUT"
      memory    = 128
      cache     = false
      cache_ttl = 0
    },
    list_my_domains = {
      runtime = "python3.13"

      method    = "GET"
      memory    = 128
      cache     = false
      cache_ttl = 0
    }
  }
}

data "aws_s3_objects" "check" {
  for_each = local.supported_lambdas
  bucket   = var.bucket
  prefix   = "lambda/${each.key}.zip.base64sha256"
}

locals {
  lambdas = {
    for l in keys(local.supported_lambdas) :
    l => local.supported_lambdas[l]
    if length(data.aws_s3_objects.check[l].keys) > 0
  }
}
