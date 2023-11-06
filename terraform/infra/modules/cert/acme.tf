# locals {
#   prod_url  = "https://acme-v02.api.letsencrypt.org/directory"
#   stage_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
# }

# provider "acme" {
#   server_url = var.prod ? local.prod_url : local.stage_url
# }

# resource "tls_private_key" "key" {
#   algorithm = "RSA"
# }

# resource "acme_registration" "reg" {
#   account_key_pem = tls_private_key.key.private_key_pem
#   email_address   = var.email
# }

# resource "tls_private_key" "pk" {
#   algorithm = "RSA"
# }

# resource "aws_ssm_parameter" "cabal_private_key" {
#   name        = "/cabal/control_domain_ssl_key"
#   description = "Cabal SSL Key"
#   type        = "SecureString"
#   value       = tls_private_key.pk.private_key_pem
# }

# resource "tls_cert_request" "csr" {
#   private_key_pem = tls_private_key.pk.private_key_pem
#   dns_names       = ["*.${var.control_domain}"]

#   subject {
#     common_name = var.control_domain
#   }
# }

# resource "acme_certificate" "cert" {
#   account_key_pem           = acme_registration.reg.account_key_pem
#   certificate_request_pem   = tls_cert_request.csr.cert_request_pem
#   recursive_nameservers = [
#     "8.8.8.8:53",
#     "8.8.4.4:53"
#   ]
#   dns_challenge {
#     provider = "route53"
#   }
# }

# resource "aws_ssm_parameter" "cert" {
#   name        = "/cabal/control_domain_ssl_cert"
#   description = "Cabal SSL Certificate"
#   type        = "SecureString"
#   value       = acme_certificate.cert.certificate_pem
# }

# resource "aws_ssm_parameter" "chain" {
#   name        = "/cabal/control_domain_chain_cert"
#   description = "Cabal Chain Certificate"
#   type        = "SecureString"
#   value       = acme_certificate.cert.issuer_pem
# }

locals {
  stage_url = "https://acme-staging-v02.api.letsencrypt.org/directory"
}

provider "acme" {
  server_url = local.stage_url
}

resource "aws_ssm_parameter" "cabal_private_key" {
  name        = "/cabal/control_domain_ssl_key"
  description = "Cabal SSL Key"
  type        = "SecureString"
  value       = <<EOC
-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAvdwJfNnU6GZnFnPFz8uqJ4qdPEYCYHVHFEGnvL6tg+rq6sCr
FV3A10Mc/GTMXPY0ECB4MDLT2mjdcWiMimL0DKtMUQChXCFsm6u+0KiHn8kVPf39
lvr6NTLNAlyUqqV37w4/7Zkh22SuIgHHpc6+MiaLzP4R33EkHemH66Uq4po/TZL6
XV1t31Nh4EmmIZq+gai0ebbuFczUirhKc2RD1gEhanyK7OCjukvJRlEHqVOwojra
FH4aT6ePuljCr839LPcoJCflA1d4E9Be4wUAaZLRqo49f5oU3u8ZTcOu0HIuR3yY
bQT5kLRPjCgql9OYk3EIOBbg1wm98fd0dHDiKQIDAQABAoIBAEK5Kbxu8ZwbIO+L
EGHOuaXb2RZtpDgx/yDnUgPLHz/VN2n4/CcuI6+DLpSk+A1TmUhxoMuPkVSYtfo9
O+cGj65EJTXyesLeHEU5Pn4mPEOzb3ux34VH/tbjW5kQ4E54iIXDBESEJJnt8CST
a46h8cW+NjN8tttH7+FzSQlPqpqn70HCQMF13PvjmGTVLWeXy7CpFmBbBBpAOru1
+4l38mwiE/nd4KhtSIiv7nygKSzsKlgvCC48FzmHQpXghnRUTc1hH1TzEzsmrJcA
unzpk2ufS4DDMg6CbCecWnLTSEuRHUVwQfLyBkE1tLxG5+b7lrjzsw2cOxWLoeVm
Jx6LmWECgYEAynZCY7KkgN3hDAdR0cU0DRK6zJpiBLM2N4+cgIar/qGyqFLxqrk1
+a+oLlZMsFc7EqyUU6VMYWS9z6ZA/Uajs1y/5PtRZHf9jKF0oIeHXGsyIjrOsd93
9q283iDwuwi9g+DNebqqzkAzTppWG5az0O1xQClRb0l4NDVgU6uuy88CgYEA8BCm
uU3nzcZ8g3Vnqm089Ad2aIXzrD0a3tOexqQInEzjJUkjnKRDD+CTKgw4NKylYpoM
PsufkQTk/ejX4OwGQIwGv6sq4o27HKUpTzvhDJgtvnacCPvCf+Rz64MZ9uezgBdl
JT2797R+oC2IvgWeyGXzMwN8hYpK8SOPEzdYGIcCgYEAtQD7I6TPe0Jic12L4Y17
loB7LnaLUQZjX1LuKN29oN0xG1lkIyyIO9y18A9JapHiBzTxOsLaQWxOYfmRup3P
togiKvYgc0DvFi42VVo1QwO3A3Et30oZNxlmc/RhI+WRgPiW2tBu6gvtksVaXDnk
MtJE4IbP/j1h0NMzdjpUAHMCgYBWEhJEs+rdO0HfPBPL5diJwbcxaH1iDpJ4u7Tc
kWlI6MQz1RJAkiA9LA53b+Qi9pdhT8v+I7F1JCUZ6AambNkdAVdWFv+MNLaWYZz6
/IQGqPUVqZ7uFZ25juYE1X9Up+QSk9C+1nBzMjKIKWsyff9c6DiW3LQjiN6vsEkW
4avjNwKBgQChRa2WNkSnckFT2jjPB59wG+aXOeSFYcDnvPXtY52yOnin71mPEOFf
OuxoNTzUsMuV6SIk4urfDSb5zYzH0h0+EfwZcYXahXGHqGI5gko/XCeSjtrBhhN8
jir2F2JKNPxoZ5hNykTALONsoIxmrrrWMZjtazKOYIAM5r2w/auCBQ==
-----END RSA PRIVATE KEY-----
EOC
}

resource "aws_ssm_parameter" "cert" {
  name        = "/cabal/control_domain_ssl_cert"
  description = "Cabal SSL Certificate"
  type        = "SecureString"
  value       = <<EOC
  -----BEGIN CERTIFICATE-----
  MIIFJzCCBA+gAwIBAgITAPpgg/CFeyXR457dYceRRNWnLjANBgkqhkiG9w0BAQsF
  ADBZMQswCQYDVQQGEwJVUzEgMB4GA1UEChMXKFNUQUdJTkcpIExldCdzIEVuY3J5
  cHQxKDAmBgNVBAMTHyhTVEFHSU5HKSBBcnRpZmljaWFsIEFwcmljb3QgUjMwHhcN
  MjMwODI4MDk1MTAzWhcNMjMxMTI2MDk1MTAyWjAYMRYwFAYDVQQDEw1jYWJhbG1h
  aWwubmV0MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAvdwJfNnU6GZn
  FnPFz8uqJ4qdPEYCYHVHFEGnvL6tg+rq6sCrFV3A10Mc/GTMXPY0ECB4MDLT2mjd
  cWiMimL0DKtMUQChXCFsm6u+0KiHn8kVPf39lvr6NTLNAlyUqqV37w4/7Zkh22Su
  IgHHpc6+MiaLzP4R33EkHemH66Uq4po/TZL6XV1t31Nh4EmmIZq+gai0ebbuFczU
  irhKc2RD1gEhanyK7OCjukvJRlEHqVOwojraFH4aT6ePuljCr839LPcoJCflA1d4
  E9Be4wUAaZLRqo49f5oU3u8ZTcOu0HIuR3yYbQT5kLRPjCgql9OYk3EIOBbg1wm9
  8fd0dHDiKQIDAQABo4ICJzCCAiMwDgYDVR0PAQH/BAQDAgWgMB0GA1UdJQQWMBQG
  CCsGAQUFBwMBBggrBgEFBQcDAjAMBgNVHRMBAf8EAjAAMB0GA1UdDgQWBBSApjOm
  3lhgiS3y4FM4+VbcWXvwjTAfBgNVHSMEGDAWgBTecnpI3zHDplDfn4Uj31c3S10u
  ZTBdBggrBgEFBQcBAQRRME8wJQYIKwYBBQUHMAGGGWh0dHA6Ly9zdGctcjMuby5s
  ZW5jci5vcmcwJgYIKwYBBQUHMAKGGmh0dHA6Ly9zdGctcjMuaS5sZW5jci5vcmcv
  MCkGA1UdEQQiMCCCDyouY2FiYWxtYWlsLm5ldIINY2FiYWxtYWlsLm5ldDATBgNV
  HSAEDDAKMAgGBmeBDAECATCCAQMGCisGAQQB1nkCBAIEgfQEgfEA7wB2AO2rnR3d
  g3OVn/UqiORrtLzDxMxNdopgzP9ONi1/uNZoAAABijvEve4AAAQDAEcwRQIgbqXm
  shzcEjJ3j66kc6Cx0kIOevVgsvEAF0v7KmJc+70CIQD2Sn1C+EyM5au51nnDQPx6
  3+ycNskpRZgA+AulxCMBXgB1ALDMg+Wl+X1rr3wJzChJBIcqx+iLEyxjULfG/Sbh
  bGx3AAABijvEv/MAAAQDAEYwRAIgYe+f3VOR9nvxxTSQ1mremiU7D0bBS4TAzAtH
  ojQriOACICkD357O0ahIAkyx4nHXMWTWVZiv/J21t0m3rKJ+3i8WMA0GCSqGSIb3
  DQEBCwUAA4IBAQBQGCe+EBveR8bts7D/67x9rGukPDPmyjzA8uJXfQmP/PAmpac1
  KQ06b2FhpttNa3k33xUeg2jQqGUOr1fMj5ujzJSSvmKX8GlgQ1BR6kUlw7xwOA//
  qc3rw6wUAC0O1MVLqeI08vOIAwBY/XcF+ByPUhokF0aDQQU7NPFrCziEtWqa25MI
  lm858SJD0wUJ3OgZuy5yfb/r5OO9mEuiE6zweV5v6YPIGwRF+vvRF18CeHUT5GpK
  jBVezjyJpl5ya1A4Ln8W6rX/pp1b/M7fnYbdp5P1io/EyWrcRjeyw4euAR/KhakS
  C4NhFjzHyrqJVZX6nS2V8OkF/XPnomcf4QGy
-----END CERTIFICATE-----
EOC
}

resource "aws_ssm_parameter" "chain" {
  name        = "/cabal/control_domain_chain_cert"
  description = "Cabal Chain Certificate"
  type        = "SecureString"
  value       = <<EOC
-----BEGIN CERTIFICATE-----
MIIFWzCCA0OgAwIBAgIQTfQrldHumzpMLrM7jRBd1jANBgkqhkiG9w0BAQsFADBm
MQswCQYDVQQGEwJVUzEzMDEGA1UEChMqKFNUQUdJTkcpIEludGVybmV0IFNlY3Vy
aXR5IFJlc2VhcmNoIEdyb3VwMSIwIAYDVQQDExkoU1RBR0lORykgUHJldGVuZCBQ
ZWFyIFgxMB4XDTIwMDkwNDAwMDAwMFoXDTI1MDkxNTE2MDAwMFowWTELMAkGA1UE
BhMCVVMxIDAeBgNVBAoTFyhTVEFHSU5HKSBMZXQncyBFbmNyeXB0MSgwJgYDVQQD
Ex8oU1RBR0lORykgQXJ0aWZpY2lhbCBBcHJpY290IFIzMIIBIjANBgkqhkiG9w0B
AQEFAAOCAQ8AMIIBCgKCAQEAu6TR8+74b46mOE1FUwBrvxzEYLck3iasmKrcQkb+
gy/z9Jy7QNIAl0B9pVKp4YU76JwxF5DOZZhi7vK7SbCkK6FbHlyU5BiDYIxbbfvO
L/jVGqdsSjNaJQTg3C3XrJja/HA4WCFEMVoT2wDZm8ABC1N+IQe7Q6FEqc8NwmTS
nmmRQm4TQvr06DP+zgFK/MNubxWWDSbSKKTH5im5j2fZfg+j/tM1bGaczFWw8/lS
nukyn5J2L+NJYnclzkXoh9nMFnyPmVbfyDPOc4Y25aTzVoeBKXa/cZ5MM+WddjdL
biWvm19f1sYn1aRaAIrkppv7kkn83vcth8XCG39qC2ZvaQIDAQABo4IBEDCCAQww
DgYDVR0PAQH/BAQDAgGGMB0GA1UdJQQWMBQGCCsGAQUFBwMCBggrBgEFBQcDATAS
BgNVHRMBAf8ECDAGAQH/AgEAMB0GA1UdDgQWBBTecnpI3zHDplDfn4Uj31c3S10u
ZTAfBgNVHSMEGDAWgBS182Xy/rAKkh/7PH3zRKCsYyXDFDA2BggrBgEFBQcBAQQq
MCgwJgYIKwYBBQUHMAKGGmh0dHA6Ly9zdGcteDEuaS5sZW5jci5vcmcvMCsGA1Ud
HwQkMCIwIKAeoByGGmh0dHA6Ly9zdGcteDEuYy5sZW5jci5vcmcvMCIGA1UdIAQb
MBkwCAYGZ4EMAQIBMA0GCysGAQQBgt8TAQEBMA0GCSqGSIb3DQEBCwUAA4ICAQCN
DLam9yN0EFxxn/3p+ruWO6n/9goCAM5PT6cC6fkjMs4uas6UGXJjr5j7PoTQf3C1
vuxiIGRJC6qxV7yc6U0X+w0Mj85sHI5DnQVWN5+D1er7mp13JJA0xbAbHa3Rlczn
y2Q82XKui8WHuWra0gb2KLpfboYj1Ghgkhr3gau83pC/WQ8HfkwcvSwhIYqTqxoZ
Uq8HIf3M82qS9aKOZE0CEmSyR1zZqQxJUT7emOUapkUN9poJ9zGc+FgRZvdro0XB
yphWXDaqMYph0DxW/10ig5j4xmmNDjCRmqIKsKoWA52wBTKKXK1na2ty/lW5dhtA
xkz5rVZFd4sgS4J0O+zm6d5GRkWsNJ4knotGXl8vtS3X40KXeb3A5+/3p0qaD215
Xq8oSNORfB2oI1kQuyEAJ5xvPTdfwRlyRG3lFYodrRg6poUBD/8fNTXMtzydpRgy
zUQZh/18F6B/iW6cbiRN9r2Hkh05Om+q0/6w0DdZe+8YrNpfhSObr/1eVZbKGMIY
qKmyZbBNu5ysENIK5MPc14mUeKmFjpN840VR5zunoU52lqpLDua/qIM8idk86xGW
xx2ml43DO/Ya/tVZVok0mO0TUjzJIfPqyvr455IsIut4RlCR9Iq0EDTve2/ZwCuG
hSjpTUFGSiQrR2JK2Evp+o6AETUkBCO1aw0PpQBPDQ==
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIFVDCCBDygAwIBAgIRAO1dW8lt+99NPs1qSY3Rs8cwDQYJKoZIhvcNAQELBQAw
cTELMAkGA1UEBhMCVVMxMzAxBgNVBAoTKihTVEFHSU5HKSBJbnRlcm5ldCBTZWN1
cml0eSBSZXNlYXJjaCBHcm91cDEtMCsGA1UEAxMkKFNUQUdJTkcpIERvY3RvcmVk
IER1cmlhbiBSb290IENBIFgzMB4XDTIxMDEyMDE5MTQwM1oXDTI0MDkzMDE4MTQw
M1owZjELMAkGA1UEBhMCVVMxMzAxBgNVBAoTKihTVEFHSU5HKSBJbnRlcm5ldCBT
ZWN1cml0eSBSZXNlYXJjaCBHcm91cDEiMCAGA1UEAxMZKFNUQUdJTkcpIFByZXRl
bmQgUGVhciBYMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBALbagEdD
Ta1QgGBWSYkyMhscZXENOBaVRTMX1hceJENgsL0Ma49D3MilI4KS38mtkmdF6cPW
nL++fgehT0FbRHZgjOEr8UAN4jH6omjrbTD++VZneTsMVaGamQmDdFl5g1gYaigk
kmx8OiCO68a4QXg4wSyn6iDipKP8utsE+x1E28SA75HOYqpdrk4HGxuULvlr03wZ
GTIf/oRt2/c+dYmDoaJhge+GOrLAEQByO7+8+vzOwpNAPEx6LW+crEEZ7eBXih6V
P19sTGy3yfqK5tPtTdXXCOQMKAp+gCj/VByhmIr+0iNDC540gtvV303WpcbwnkkL
YC0Ft2cYUyHtkstOfRcRO+K2cZozoSwVPyB8/J9RpcRK3jgnX9lujfwA/pAbP0J2
UPQFxmWFRQnFjaq6rkqbNEBgLy+kFL1NEsRbvFbKrRi5bYy2lNms2NJPZvdNQbT/
2dBZKmJqxHkxCuOQFjhJQNeO+Njm1Z1iATS/3rts2yZlqXKsxQUzN6vNbD8KnXRM
EeOXUYvbV4lqfCf8mS14WEbSiMy87GB5S9ucSV1XUrlTG5UGcMSZOBcEUpisRPEm
QWUOTWIoDQ5FOia/GI+Ki523r2ruEmbmG37EBSBXdxIdndqrjy+QVAmCebyDx9eV
EGOIpn26bW5LKerumJxa/CFBaKi4bRvmdJRLAgMBAAGjgfEwge4wDgYDVR0PAQH/
BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFLXzZfL+sAqSH/s8ffNE
oKxjJcMUMB8GA1UdIwQYMBaAFAhX2onHolN5DE/d4JCPdLriJ3NEMDgGCCsGAQUF
BwEBBCwwKjAoBggrBgEFBQcwAoYcaHR0cDovL3N0Zy1kc3QzLmkubGVuY3Iub3Jn
LzAtBgNVHR8EJjAkMCKgIKAehhxodHRwOi8vc3RnLWRzdDMuYy5sZW5jci5vcmcv
MCIGA1UdIAQbMBkwCAYGZ4EMAQIBMA0GCysGAQQBgt8TAQEBMA0GCSqGSIb3DQEB
CwUAA4IBAQB7tR8B0eIQSS6MhP5kuvGth+dN02DsIhr0yJtk2ehIcPIqSxRRmHGl
4u2c3QlvEpeRDp2w7eQdRTlI/WnNhY4JOofpMf2zwABgBWtAu0VooQcZZTpQruig
F/z6xYkBk3UHkjeqxzMN3d1EqGusxJoqgdTouZ5X5QTTIee9nQ3LEhWnRSXDx7Y0
ttR1BGfcdqHopO4IBqAhbkKRjF5zj7OD8cG35omywUbZtOJnftiI0nFcRaxbXo0v
oDfLD0S6+AC2R3tKpqjkNX6/91hrRFglUakyMcZU/xleqbv6+Lr3YD8PsBTub6lI
oZ2lS38fL18Aon458fbc0BPHtenfhKj5
-----END CERTIFICATE-----
EOC
}