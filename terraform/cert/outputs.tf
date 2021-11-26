output "public_key" {
  value = tls_private_key.pk.public_key_pem
}

output "private_key" {
  value = tls_private_key.pk.private_key_pem
  sensitive = true
}

output "cert" {
  value = acme_certificate.cert.certificate_pem
}

output "intermediate" {
  value = acme_certificate.cert.issuer_pem
}