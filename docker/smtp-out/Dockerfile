FROM amazonlinux:2023@sha256:181f98c48832fe926f8ca3b6ffeafcce128e96e77b93d08fbe9a9bc9403ce284

# System packages
# AL2023 pins $releasever to the base image's own release snapshot, so
# dnf here only ever sees the package set frozen at base-image build
# time; security updates AWS publishes later are invisible, and no
# rebuild picks them up. Track the current snapshot and upgrade first.
# The upgrade is the load-bearing half: packages that ship in the base
# (openssl-libs, glib2, ...) are named in no install line below and
# would otherwise keep the base image's versions forever.
RUN echo latest > /etc/dnf/vars/releasever \
    && dnf -y upgrade \
    && dnf install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      dovecot \
      opendkim \
      procmail \
      rsyslog \
      make \
      procps-ng \
      awscli-2 jq \
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

# Dovecot submission configuration
COPY smtp-out/configs/dovecot/00-protocols.conf   /etc/dovecot/conf.d/00-protocols.conf
COPY smtp-out/configs/dovecot/10-auth.conf        /etc/dovecot/conf.d/10-auth.conf
COPY smtp-out/configs/dovecot/10-mail.conf        /etc/dovecot/conf.d/10-mail.conf
COPY smtp-out/configs/dovecot/10-logging.conf     /etc/dovecot/conf.d/10-logging.conf
COPY smtp-out/configs/dovecot/15-mailboxes.conf   /etc/dovecot/conf.d/15-mailboxes.conf
COPY smtp-out/configs/dovecot/20-submission.conf  /etc/dovecot/conf.d/20-submission.conf

# PAM for dovecot (Cognito auth)
COPY smtp-out/configs/pam/dovecot                /etc/pam.d/dovecot

# OpenDKIM static configuration
COPY smtp-out/configs/opendkim.conf        /etc/opendkim.conf

# Static sendmail access map
COPY smtp-out/configs/out-access           /etc/mail/access

# Sendmail .mc template (placeholder for cert domain)
COPY templates/out-sendmail.mc             /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh
COPY shared/prepare-sendmail.sh            /usr/local/bin/prepare-sendmail.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-out/supervisord.conf             /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 465 587

ENTRYPOINT ["/entrypoint.sh"]
