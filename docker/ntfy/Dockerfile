FROM binwiederhier/ntfy:v2.25.0@sha256:cfbbb1bac9196cb711e29ef0ac4adaeb033be6235f1df857705dc39c14384a1d

# The upstream image listens on 80 by default when NTFY_LISTEN_HTTP=:80.
# Cache + auth DB are expected at /var/cache/ntfy/ (EFS-backed in the
# task definition). Config is fully env-var driven (NTFY_*); no YAML
# file is needed.
#
# Token auth + deny-all default is applied via the task definition, not
# here, to keep the image environment-agnostic.

EXPOSE 80
