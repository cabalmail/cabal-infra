- **Dropped the sendmail package's throwaway self-signed cert/key from the
  `imap`, `smtp-in`, and `smtp-out` images.** The `sendmail` RPM generates a
  self-signed `/etc/pki/tls/private/sendmail.key` during install; it was
  never read (the real cert/key are injected at runtime under a different
  filename) but still shipped in the image and tripped secret scanners.
