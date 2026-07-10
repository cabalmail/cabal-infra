- **CAA records authorizing our certificate authorities.** A new
  `terraform/infra/modules/caa` module publishes CAA records that lock
  certificate issuance to the CAs Cabalmail actually uses: ACM plus Let's
  Encrypt on the control domain, ACM only on the mail domains (Let's Encrypt is
  used only on the control domain). Each record carries an `iodef` violation
  contact pointing at the system-managed `caa-reports@mail-admin.` address.
  See [docs/caa.md](docs/caa.md).
