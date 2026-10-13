"""Lambda handler that renews Let's Encrypt certificates using certbot
and stores them in SSM Parameter Store."""

import datetime
import json
import os
import subprocess
import urllib.error
import urllib.request

import boto3
from cryptography import x509


SSM_PATHS = {
    "privkey": "/cabal/control_domain_ssl_key",
    "cert": "/cabal/control_domain_ssl_cert",
    "chain": "/cabal/control_domain_chain_cert",
}

# The schedule runs daily; a run renews only once less than this fraction of
# the current certificate's lifetime remains. Reading the lifetime off the
# certificate instead of fixing a day count tracks Let's Encrypt's shrinking
# lifetimes (90 days, then 64 from Feb 2027, then 45 from Feb 2028) without
# a code change. Half the lifetime keeps renewal clear of the 21-day
# BlackboxTLSCertExpiringSoonWarning alert even at 45 days, and leaves weeks
# of daily retries if issuance fails.
RENEW_FRACTION = 0.5

PING_PARAM = os.environ.get("HEALTHCHECK_PING_PARAM", "")
_PING_URL = None


def _ping_healthcheck(ssm):
    """Best-effort heartbeat to Healthchecks. Silent on failure."""
    global _PING_URL  # pylint: disable=global-statement
    if _PING_URL is None:
        if not PING_PARAM:
            _PING_URL = ""
        else:
            try:
                resp = ssm.get_parameter(Name=PING_PARAM, WithDecryption=True)
                value = resp["Parameter"]["Value"]
                _PING_URL = value if value.startswith("http") else ""
            except Exception as err:  # pylint: disable=broad-exception-caught
                print(f"healthcheck ping URL fetch failed: {err}")
                _PING_URL = ""
    if not _PING_URL:
        return
    try:
        with urllib.request.urlopen(_PING_URL, timeout=5) as resp:
            print(f"healthcheck ping -> {resp.status}")
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as err:
        print(f"healthcheck ping failed: {err}")


def _renewal_due(ssm, domain, now):
    """Return (due, reason) for the certificate currently in SSM.

    Anything we can't read or parse - the bootstrap placeholder, a missing
    parameter, a certificate for another name - counts as due, so a broken
    state heals itself on the next run rather than waiting it out.
    """
    try:
        resp = ssm.get_parameter(Name=SSM_PATHS["cert"], WithDecryption=True)
        cert = x509.load_pem_x509_certificate(
            resp["Parameter"]["Value"].encode("utf-8")
        )
    except Exception as err:  # pylint: disable=broad-exception-caught
        return True, f"current certificate unreadable ({err})"

    try:
        san = cert.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value
        names = san.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound:
        names = []
    if f"*.{domain}" not in names:
        return True, f"current certificate does not cover *.{domain}"

    not_before = cert.not_valid_before_utc
    not_after = cert.not_valid_after_utc
    lifetime = not_after - not_before
    remaining = not_after - now
    threshold = lifetime * RENEW_FRACTION
    summary = (
        f"expires {not_after.isoformat()}, {remaining.days} days left "
        f"of {lifetime.days}; renews below {threshold.days}"
    )
    return remaining < threshold, summary


def handler(event, context):
    """Renew the certificate if due, write it to SSM, and restart ECS services.

    Invoke with {"force": true} to renew regardless of the current
    certificate's remaining lifetime.
    """

    domain = os.environ["CONTROL_DOMAIN"]
    email = os.environ["EMAIL"]
    cluster_name = os.environ["ECS_CLUSTER_NAME"]
    service_names = [
        s for s in os.environ.get("ECS_SERVICE_NAMES", "").split(",") if s
    ]

    ssm = boto3.client("ssm")
    force = isinstance(event, dict) and event.get("force") is True
    due, reason = _renewal_due(
        ssm, domain, datetime.datetime.now(datetime.timezone.utc)
    )
    print(f"Current certificate: {reason}")
    if not (due or force):
        _ping_healthcheck(ssm)
        return {
            "statusCode": 200,
            "body": json.dumps({"message": "Renewal not due", "detail": reason}),
        }
    if force and not due:
        print("Renewal not due, but forced by the invocation event")

    # Run certbot against Let's Encrypt production in every environment.
    # Staging certs aren't trusted by OS certificate stores, so a TestFlight
    # build of the Apple client can't complete the implicit-TLS handshake
    # with smtp-out on 465 when the container holds a staging cert.
    cmd = [
        "certbot", "certonly",
        "--dns-route53",
        "--non-interactive",
        "--agree-tos",
        "--email", email,
        "--domains", f"*.{domain}",
        "--config-dir", "/tmp/certbot/config",
        "--work-dir", "/tmp/certbot/work",
        "--logs-dir", "/tmp/certbot/logs",
    ]

    print(f"Running certbot for *.{domain}")
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    print(result.stdout)
    if result.returncode != 0:
        print(result.stderr)
        raise RuntimeError(f"certbot exited with code {result.returncode}")

    # Read generated certificate files
    cert_dir = f"/tmp/certbot/config/live/{domain}"
    file_map = {
        "privkey": f"{cert_dir}/privkey.pem",
        "cert": f"{cert_dir}/cert.pem",
        "chain": f"{cert_dir}/chain.pem",
    }

    for key, path in file_map.items():
        with open(path, "r", encoding="utf-8") as f:
            value = f.read()
        ssm.put_parameter(
            Name=SSM_PATHS[key],
            Value=value,
            Type="SecureString",
            Overwrite=True,
        )
        print(f"Updated SSM parameter {SSM_PATHS[key]}")

    # Force new ECS deployments so containers pick up the new certs
    if service_names:
        ecs = boto3.client("ecs")
        for service_name in service_names:
            ecs.update_service(
                cluster=cluster_name,
                service=service_name,
                forceNewDeployment=True,
            )
            print(f"Forced new deployment for {service_name}")

    _ping_healthcheck(ssm)

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Certificate renewed successfully"}),
    }
