divert(-1)
include(`/usr/share/sendmail-cf/m4/cf.m4')
OSTYPE(`linux')dnl
define(`confLOG_LEVEL', `2')dnl
define(`confPID_FILE', `/var/run/sendmail.pid')dnl
define(`confDEF_USER_ID',``8:12'')
define(`ALIAS_FILE',`/etc/aliases')dnl
define(`confPRIVACY_FLAGS', `authwarnings,needmailhelo,noexpn,novrfy,restrictmailq')dnl
dnl Consult /etc/hosts (files) before DNS when canonicalizing relay
dnl hosts, so the IMAP pin maintained by hosts-pin.sh is honored. Without
dnl it sendmail can go straight to the VPC resolver and a Cloud Map
dnl NXDOMAIN during an IMAP deploy becomes a permanent 5xx "Host unknown"
dnl bounce instead of a queueable 4xx. Switch file shipped at
dnl /etc/mail/service.switch by docker/smtp-in/Dockerfile.
define(`confSERVICE_SWITCH_FILE', `/etc/mail/service.switch')dnl
dnl Resource and rate limits (phase 5 of
dnl docs/0.10.x/container-runtime-hardening-plan.md): cap message size at
dnl 50 MB, bound concurrent daemon children, and throttle connection
dnl bursts from a single source. confREJECT_LOG_INTERVAL rate-limits the
dnl log volume when a sender is rejected repeatedly.
define(`confMAX_MESSAGE_SIZE', `52428800')dnl
define(`confMAX_DAEMON_CHILDREN', `40')dnl
define(`confCONNECTION_RATE_THROTTLE', `5')dnl
define(`confREJECT_LOG_INTERVAL', `3h')dnl
define(`confTO_QUEUERETURN', `4d')dnl
define(`confTO_QUEUEWARN', `4h')dnl
define(`confTO_ICONNECT', `15s')dnl
define(`confTO_CONNECT', `3m')dnl
define(`confTO_HELO', `2m')dnl
define(`confTO_MAIL', `1m')dnl
define(`confTO_RCPT', `1m')dnl
define(`confTO_DATAINIT', `1m')dnl
define(`confTO_DATABLOCK', `1m')dnl
define(`confTO_DATAFINAL', `1m')dnl
define(`confTO_RSET', `1m')dnl
define(`confTO_QUIT', `1m')dnl
define(`confTO_MISC', `1m')dnl
define(`confTO_COMMAND', `1m')dnl
define(`confTO_STARTTLS', `2m')dnl
undefine(`UUCP_RELAY')dnl
undefine(`BITNET_RELAY')dnl
define(`PROCMAIL_MAILER_PATH',`/usr/bin/procmail')dnl
dnl No SMTP AUTH on the inbound relay (phase 5 of
dnl docs/0.10.x/container-runtime-hardening-plan.md). smtp-in accepts mail
dnl for hosted domains from the internet and never authenticates senders;
dnl submission auth lives on smtp-out via Dovecot. Advertising AUTH here -
dnl especially the legacy DIGEST-MD5/CRAM-MD5 mechanisms (RFC 6331
dnl obsoleted DIGEST-MD5) - was dead, weak surface, so the
dnl confAUTH_OPTIONS / TRUST_AUTH_MECH / confAUTH_MECHANISMS stanza is
dnl removed. STARTTLS (confSERVER_CERT below) is unaffected.
define(`confCACERT_PATH', `/etc/pki/tls/certs')dnl
define(`confCACERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.ca-bundle')dnl
define(`confSERVER_CERT', `/etc/pki/tls/certs/__CERT_DOMAIN__.crt')dnl
define(`confSERVER_KEY', `/etc/pki/tls/private/__CERT_DOMAIN__.key')dnl
FEATURE(`always_add_domain')dnl
MASQUERADE_DOMAIN_FILE(`/etc/mail/masq-domains')dnl
FEATURE(`nouucp',`reject')dnl
FEATURE(`genericstable', `hash -o /etc/mail/genericstable')dnl
FEATURE(`mailertable', `hash -o /etc/mail/mailertable')dnl
FEATURE(`access_db', `hash -T<TMPF> /etc/mail/access')dnl
FEATURE(`greet_pause', 5000)dnl
FEATURE(`blacklist_recipients')dnl
FEATURE(`no_default_msa')dnl
DAEMON_OPTIONS(`Name=MTA')dnl
MAILER(procmail)dnl
MAILER(smtp)dnl
