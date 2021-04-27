output "public_key" {
  value = tls_private_key.cabal_cert_private_key.public_key_pem
}