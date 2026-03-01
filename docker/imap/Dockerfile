FROM amazonlinux:2023

# System packages
RUN dnf install -y \
      sendmail sendmail-cf \
      dovecot \
      fail2ban \
      procmail \
      rsyslog \
      httpd-tools \
      make \
      awscli-2 jq \
      pip \
    && pip install supervisor \
    && dnf clean all

# Static dovecot configuration
COPY imap/configs/dovecot/10-auth.conf       /etc/dovecot/conf.d/10-auth.conf
COPY imap/configs/dovecot/10-mail.conf       /etc/dovecot/conf.d/10-mail.conf
COPY imap/configs/dovecot/15-mailboxes.conf  /etc/dovecot/conf.d/15-mailboxes.conf
COPY imap/configs/dovecot/20-imap.conf       /etc/dovecot/conf.d/20-imap.conf
COPY imap/configs/dovecot/auth-master.conf   /etc/dovecot/conf.d/auth-master.conf.ext
COPY imap/configs/dovecot/10-logging.conf    /etc/dovecot/conf.d/10-logging.conf

# PAM for dovecot (Cognito auth)
COPY imap/configs/pam/dovecot               /etc/pam.d/dovecot

# Procmail
COPY imap/configs/procmailrc                /etc/procmailrc

# Static system aliases (dynamic aliases appended at startup)
COPY shared/aliases.static                 /etc/aliases.static

# Sendmail .mc template (placeholder for cert domain)
COPY templates/imap-sendmail.mc             /etc/mail/sendmail.mc.template

# Shared scripts
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh
COPY shared/sendmail-wrapper.sh            /usr/local/bin/sendmail-wrapper.sh

# Rsyslog config (ships sendmail logs to /var/log/maillog for CloudWatch)
COPY shared/rsyslog-mail.conf              /etc/rsyslog.conf

# Supervisord config
COPY imap/supervisord.conf                 /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 143 993 25

ENTRYPOINT ["/entrypoint.sh"]
