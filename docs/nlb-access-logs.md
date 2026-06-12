# NLB access logs

The mail Network Load Balancer writes access logs to a dedicated S3 bucket, `cabal-nlb-access-logs-<account-id>`, under the `mail-nlb/` prefix. The bucket is versioned, encrypted (SSE-S3), blocked from public access, and lifecycled: log objects expire after 180 days, noncurrent versions after 30, and incomplete multipart uploads are aborted after 7. The Terraform lives in [`terraform/infra/modules/elb/access_logs.tf`](../terraform/infra/modules/elb/access_logs.tf).

## What is (and is not) in these logs

NLB access logs are produced **only for TLS listeners**, and only for TLS connections. On this load balancer that means:

| Listener | Port | Logged? |
| -------- | ---- | ------- |
| IMAPS | 993 | Yes - TLS terminates at the NLB |
| SMTP relay | 25 | No - TCP passthrough |
| SMTP submission (implicit TLS) | 465 | No - TCP passthrough |
| SMTP submission (STARTTLS) | 587 | No - TCP passthrough |

For the SMTP tiers, TLS terminates inside the containers (sendmail/Dovecot), so the NLB never sees a handshake to log. Incident response for SMTP abuse still goes through the container logs in CloudWatch. Moving 465/587 termination to the NLB would change certificate ownership and the client-visible handshake, and is a separate decision.

Each log entry records the client IP and port, the negotiated TLS protocol and cipher, handshake timing, bytes in/out, and the SNI name the client sent. Delivery is one gzipped object per load-balancer node per 5 minutes, best-effort, under:

```
s3://cabal-nlb-access-logs-<account>/mail-nlb/AWSLogs/<account>/elasticloadbalancing/<region>/<yyyy>/<mm>/<dd>/
```

## Querying with Athena

The Athena table is not Terraform-managed (Athena/Glue would be a new service surface for the CI deploy policy, and the table is trivially recreated). Create it once per account from the Athena console or CLI:

```sql
CREATE DATABASE IF NOT EXISTS cabal_logs;

CREATE EXTERNAL TABLE IF NOT EXISTS cabal_logs.mail_nlb_logs (
    type string,
    version string,
    time string,
    elb string,
    listener_id string,
    client_ip string,
    client_port int,
    target_ip string,
    target_port int,
    tcp_connection_time_ms double,
    tls_handshake_time_ms double,
    received_bytes bigint,
    sent_bytes bigint,
    incoming_tls_alert int,
    cert_arn string,
    certificate_serial string,
    tls_cipher_suite string,
    tls_protocol_version string,
    tls_named_group string,
    domain_name string,
    alpn_fe_protocol string,
    alpn_be_protocol string,
    alpn_client_preference_list string,
    tls_connection_creation_time string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.RegexSerDe'
WITH SERDEPROPERTIES (
    'serialization.format' = '1',
    'input.regex' =
        '([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*):([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-0-9]*) ([-0-9]*) ([-0-9]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*)$')
LOCATION 's3://cabal-nlb-access-logs-<account-id>/mail-nlb/AWSLogs/<account-id>/elasticloadbalancing/<region>/';
```

Replace `<account-id>` and `<region>`. Example investigation queries:

```sql
-- Top client IPs by connection count over the scanned window
SELECT client_ip, count(*) AS connections
FROM cabal_logs.mail_nlb_logs
GROUP BY client_ip
ORDER BY connections DESC
LIMIT 25;

-- Handshake failures (no protocol negotiated), often scanners
SELECT time, client_ip, incoming_tls_alert
FROM cabal_logs.mail_nlb_logs
WHERE tls_protocol_version = '-'
ORDER BY time DESC
LIMIT 100;

-- Clients negotiating old TLS versions
SELECT tls_protocol_version, count(*) AS connections
FROM cabal_logs.mail_nlb_logs
GROUP BY tls_protocol_version;
```

Athena scans by S3 prefix; constrain cost on big buckets by pointing `LOCATION` at a narrower `<yyyy>/<mm>` prefix for one-off investigations.

## Retention

180 days, set in the bucket lifecycle rule. If a compliance regime ever demands longer, bump `expiration.days` in `access_logs.tf` - a one-line change.
