locals {
  prod_url  = "https://acme-v02.api.letsencrypt.org/directory"
  stage_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

provider "acme" {
  server_url = var.prod ? local.prod_url : local.stage_url
}

resource "tls_private_key" "cabal_reg_private_key" {
  algorithm = "RSA"
}

resource "acme_registration" "cabal_registration" {
  account_key_pem = tls_private_key.cabal_reg_private_key.private_key_pem
  email_address   = var.email
}

resource "tls_private_key" "cabal_cert_private_key" {
  algorithm = "RSA"
}

resource "tls_cert_request" "cabal_request" {
  key_algorithm             = "RSA"
  private_key_pem           = tls_private_key.cabal_cert_private_key.private_key_pem
  dns_names                 = ["*.${var.domain}"]

  subject {
    common_name = var.domain
  }
}

resource "acme_certificate" "cabal_certificate" {
  account_key_pem           = acme_registration.cabal_registration.account_key_pem
  certificate_request_pem   = tls_cert_request.cabal_request.cert_request_pem
  recursive_nameservers = [
    "8.8.8.8:53",
    "8.8.4.4:53"
  ]
  dns_challenge {
    provider = "route53"
  }
}