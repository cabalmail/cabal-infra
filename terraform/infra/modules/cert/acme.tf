locals {
  prod_url  = "https://acme-v02.api.letsencrypt.org/directory"
  stage_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

provider "acme" {
  server_url = var.prod ? local.prod_url : local.stage_url
}

resource "tls_private_key" "key" {
  algorithm = "RSA"
}

resource "acme_registration" "reg" {
  account_key_pem = tls_private_key.key.private_key_pem
  email_address   = var.email
}

resource "tls_private_key" "pk" {
  algorithm = "RSA"
}

resource "aws_ssm_parameter" "cabal_private_key" {
  name        = "/cabal/control_domain_ssl_key"
  description = "Cabal SSL Key"
  type        = "SecureString"
  value       = tls_private_key.pk.private_key_pem
}

resource "tls_cert_request" "csr" {
  private_key_pem = tls_private_key.pk.private_key_pem
  dns_names       = ["*.${var.control_domain}"]

  subject {
    common_name = var.control_domain
  }
}

resource "acme_certificate" "cert" {
  account_key_pem           = acme_registration.reg.account_key_pem
  certificate_request_pem   = tls_cert_request.csr.cert_request_pem
  recursive_nameservers = [
    "8.8.8.8:53",
    "8.8.4.4:53"
  ]
  dns_challenge {
    provider = "route53"
  }
}

resource "aws_ssm_parameter" "cert" {
  name        = "/cabal/control_domain_ssl_cert"
  description = "Cabal SSL Certificate"
  type        = "SecureString"
  value       = acme_certificate.cert.certificate_pem
}

resource "aws_ssm_parameter" "chain" {
  name        = "/cabal/control_domain_chain_cert"
  description = "Cabal Chain Certificate"
  type        = "SecureString"
  value       = acme_certificate.cert.issuer_pem
}