output "public_key" {
  value = tls_private_key.cabal_cert_private_key.public_key_pem
}

output "private_key" {
  value = tls_private_key.cabal_cert_private_key.private_key_pem
}

output "cert" {
  value = acme_certificate.cabal_certificate.certificate_pem
}

output "intermediate" {
  value = acme_certificate.cabal_certificate.issuer_pem
}