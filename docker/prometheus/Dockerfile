FROM prom/prometheus:v3.15.1@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2

USER root

COPY prometheus/prometheus.yml /etc/prometheus/prometheus.yml
COPY prometheus/rules/ /etc/prometheus/rules/
COPY prometheus/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/prometheus-rendered \
    && chown -R nobody:nobody /etc/prometheus-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
