FROM prom/alertmanager:v0.34.0@sha256:690c7b525f4367aa91f73e2f91c632206d32e97c6384bdbf2fb7a861b420340d

USER root

COPY alertmanager/alertmanager.yml.tmpl /etc/alertmanager/alertmanager.yml.tmpl
COPY alertmanager/entrypoint.sh /usr/local/bin/cabal-entrypoint.sh
RUN chmod +x /usr/local/bin/cabal-entrypoint.sh \
    && mkdir -p /etc/alertmanager-rendered \
    && chown -R nobody:nobody /etc/alertmanager-rendered

USER nobody

ENTRYPOINT ["/usr/local/bin/cabal-entrypoint.sh"]
