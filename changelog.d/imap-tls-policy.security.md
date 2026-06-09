- The IMAP-over-TLS load balancer listener (port 993) now pins
  `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` (TLS 1.2/1.3, strong
  ciphers). It previously set no policy, so the NLB defaulted to one that
  still accepted TLS 1.0/1.1 on the client-facing IMAPS endpoint.
