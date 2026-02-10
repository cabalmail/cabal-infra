FROM amazonlinux:2

# Enable EPEL (for fail2ban, opendkim, supervisor) and install Python 3
RUN amazon-linux-extras install epel python3.8 -y

# System packages
RUN yum install -y \
      sendmail sendmail-cf \
      sendmail-milter \
      opendkim \
      fail2ban \
      procmail \
      awscli jq \
      python3-pip \
      supervisor \
    && yum clean all

# PAM for sendmail (Cognito auth)
COPY smtp-out/configs/pam/smtp             /etc/pam.d/smtp

# OpenDKIM static configuration
COPY smtp-out/configs/opendkim.conf        /etc/opendkim.conf

# Static sendmail access map
COPY smtp-out/configs/out-access           /etc/mail/access

# Sendmail .mc template (placeholder for cert domain)
COPY templates/out-sendmail.mc             /etc/mail/sendmail.mc.template

# Shared scripts (Phase 2 will populate these)
COPY shared/entrypoint.sh                  /entrypoint.sh
COPY shared/generate-config.sh             /usr/local/bin/generate-config.sh
COPY shared/sync-users.sh                  /usr/local/bin/sync-users.sh
COPY shared/reconfigure.sh                 /usr/local/bin/reconfigure.sh

# Supervisord config
COPY smtp-out/supervisord.conf             /etc/supervisord.conf

RUN chmod +x /entrypoint.sh /usr/local/bin/*.sh

EXPOSE 25 465 587

ENTRYPOINT ["/entrypoint.sh"]
