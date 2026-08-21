# ── Builder stage: OpenDMARC from source ─────────────────────────────
# AL2023 does not package opendmarc (confirmed against the core repo
# metadata, 2026-07-05; opendkim IS packaged) and the OpenDMARC project
# publishes no dist tarballs, only release tags, so this compiles the
# pinned tag archive with autotools. libspf2 is also not packaged for
# AL2023, so --with-spf enables OpenDMARC's internal SPF implementation
# (consumed via SPFSelfValidate in opendmarc.conf). Phase 1 of
# docs/0.10.x/inbound-auth-verification-plan.md.
FROM amazonlinux:2023@sha256:181f98c48832fe926f8ca3b6ffeafcce128e96e77b93d08fbe9a9bc9403ce284 AS opendmarc-build

RUN dnf install -y \
      gcc make autoconf automake libtool \
      sendmail-milter-devel \
      tar gzip \
    && dnf clean all

# Pin by tag + checksum of the GitHub tag archive (supply-chain plan
# style). A checksum mismatch fails the build loudly.
ARG OPENDMARC_TAG=rel-opendmarc-1-4-2
ARG OPENDMARC_SHA256=ee1dcdd158fd5fd2b16de2b86980c4a4be60a070641ca19591a713da4e4008bb

RUN curl -fsSL -o /tmp/opendmarc.tar.gz \
      "https://github.com/trusteddomainproject/OpenDMARC/archive/refs/tags/${OPENDMARC_TAG}.tar.gz" \
    && echo "${OPENDMARC_SHA256}  /tmp/opendmarc.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/opendmarc.tar.gz -C /tmp \
    && cd "/tmp/OpenDMARC-${OPENDMARC_TAG}" \
    && autoreconf -fiv \
    && ./configure --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib64 \
         --with-spf --with-milter=/usr \
    && make \
    && make DESTDIR=/stage install

# ── Runtime stage ─────────────────────────────────────────────────────
FROM amazonlinux:2023@sha256:181f98c48832fe926f8ca3b6ffeafcce128e96e77b93d08fbe9a9bc9403ce284

# System packages. opendkim runs in verify-only mode as the first
# inbound-auth milter; sendmail-milter provides the libmilter shared
# library the source-built opendmarc links against.
RUN dnf install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      opendkim \
      procmail \
      rsyslog \
      make \
      procps-ng \
      awscli-2 jq \
      bind-utils \
      pip \
    && pip install supervisor \
    && dnf clean all \
    && sed -i 's/^UID_MAX.*/UID_MAX                 2147483647/' /etc/login.defs \
    && sed -i 's/^GID_MAX.*/GID_MAX                 2147483647/' /etc/login.defs \
    # The sendmail RPM's %post scriptlet generates a throwaway self-signed
    # cert/key here on every install; entrypoint.sh always overwrites the
    # real TLS_CERT/TLS_KEY under different filenames, so this baked-in
    # key is unused and would flag as a leaked private key.
    && rm -f /etc/pki/tls/private/sendmail.key /etc/pki/tls/certs/sendmail.pem

# OpenDMARC binary + library from the builder stage (opendmarc-check and
# the perl reporting tools are deliberately not copied), plus a service
# account and runtime dir. Ownership is set here at build time: the
# smtp-in task definition drops CHOWN, so the entrypoint cannot chown.
COPY --from=opendmarc-build /stage/usr/sbin/opendmarc /usr/sbin/opendmarc
COPY --from=opendmarc-build /stage/usr/lib64/ /usr/lib64/
RUN groupadd -r opendmarc \
    && useradd -r -g opendmarc -s /sbin/nologin -d /var/tmp opendmarc \
    && install -d -o opendmarc -g opendmarc /var/run/opendmarc

# Sendmail .mc template (placeholder for cert domain)
COPY templates/in-sendmail.mc               /etc/mail/sendmail.mc.template

# Inbound-auth milter config templates (rendered by entrypoint.sh, which
# substitutes __CERT_DOMAIN__ the same way prepare-sendmail.sh renders
# sendmail.mc) and the opendmarc connection-ignore list.
COPY smtp-in/configs/opendkim.conf          /etc/opendkim.conf.template
COPY smtp-in/configs/opendmarc.conf         /etc/opendmarc.conf.template
COPY smtp-in/configs/opendmarc.ignore.hosts /etc/opendmarc.ignore.hosts

# Sendmail service switch: consult /etc/hosts before DNS so the
# hosts-pin.sh IMAP pin is honored (see docker/shared/hosts-pin.sh).
COPY shared/service.switch                  /etc/mail/service.switch

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh
COPY shared/prepare-sendmail.sh            /usr/local/bin/prepare-sendmail.sh
COPY shared/hosts-pin.sh                   /usr/local/bin/hosts-pin.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-in/supervisord.conf              /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25

ENTRYPOINT ["/entrypoint.sh"]
