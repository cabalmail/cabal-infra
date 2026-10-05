FROM prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e

USER root

COPY prometheus/prometheus.yml /etc/prometheus/prometheus.yml
COPY prometheus/rules/ /etc/prometheus/rules/
COPY prometheus/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/prometheus-rendered \
    && chown -R nobody:nobody /etc/prometheus-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
