FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      dovecot \
      opendkim \
      fail2ban \
      procmail \
      rsyslog \
      make \
      awscli-2 jq \
      pip \
    && pip install supervisor \
    && dnf clean all

# Dovecot submission configuration
COPY smtp-out/configs/dovecot/00-protocols.conf   /etc/dovecot/conf.d/00-protocols.conf
COPY smtp-out/configs/dovecot/10-auth.conf        /etc/dovecot/conf.d/10-auth.conf
COPY smtp-out/configs/dovecot/10-mail.conf        /etc/dovecot/conf.d/10-mail.conf
COPY smtp-out/configs/dovecot/10-logging.conf     /etc/dovecot/conf.d/10-logging.conf
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

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY smtp-out/supervisord.conf             /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 465 587

ENTRYPOINT ["/entrypoint.sh"]
