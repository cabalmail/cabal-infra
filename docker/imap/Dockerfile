FROM amazonlinux:2

# Enable EPEL (for fail2ban, supervisor) and install Python 3
RUN amazon-linux-extras install epel python3.8 -y

# System packages
RUN yum install -y \
      sendmail sendmail-cf \
      dovecot \
      fail2ban \
      procmail \
      httpd-tools \
      awscli jq \
      python3-pip \
      supervisor \
    && yum clean all

# Static dovecot configuration
COPY imap/configs/dovecot/10-auth.conf       /etc/dovecot/conf.d/10-auth.conf
COPY imap/configs/dovecot/10-mail.conf       /etc/dovecot/conf.d/10-mail.conf
COPY imap/configs/dovecot/15-mailboxes.conf  /etc/dovecot/conf.d/15-mailboxes.conf
COPY imap/configs/dovecot/20-imap.conf       /etc/dovecot/conf.d/20-imap.conf
COPY imap/configs/dovecot/auth-master.conf   /etc/dovecot/conf.d/auth-master.conf.ext

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

# Supervisord config
COPY imap/supervisord.conf                 /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 143 993 25

ENTRYPOINT ["/entrypoint.sh"]
