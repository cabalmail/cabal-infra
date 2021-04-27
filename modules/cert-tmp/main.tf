locals {
  prod_url  = "https://acme-v02.api.letsencrypt.org/directory"
  stage_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

provider "acme" {
  server_url = var.prod ? local.prod_url : local.stage_url
}

