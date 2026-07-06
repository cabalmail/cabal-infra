FROM prom/prometheus:v3.13.0@sha256:c6b27ea434f8389bfe233fbc7be381cf50587c286e871bc842008f5a1b1908a7

USER root

COPY prometheus/prometheus.yml /etc/prometheus/prometheus.yml
COPY prometheus/rules/ /etc/prometheus/rules/
COPY prometheus/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/prometheus-rendered \
    && chown -R nobody:nobody /etc/prometheus-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
