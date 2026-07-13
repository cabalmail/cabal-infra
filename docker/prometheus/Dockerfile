FROM prom/prometheus:v3.13.1@sha256:3c42b892cf723fa54d2f262c37a0e1f80aa8c8ddb1da7b9b0df9455a35a7f893

USER root

COPY prometheus/prometheus.yml /etc/prometheus/prometheus.yml
COPY prometheus/rules/ /etc/prometheus/rules/
COPY prometheus/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/prometheus-rendered \
    && chown -R nobody:nobody /etc/prometheus-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
