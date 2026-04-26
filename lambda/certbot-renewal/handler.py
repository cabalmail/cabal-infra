"""Lambda handler that renews Let's Encrypt certificates using certbot
and stores them in SSM Parameter Store."""

import json
import os
import subprocess
import urllib.error
import urllib.request

import boto3


SSM_PATHS = {
    "privkey": "/cabal/control_domain_ssl_key",
    "cert": "/cabal/control_domain_ssl_cert",
    "chain": "/cabal/control_domain_chain_cert",
}

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


def handler(event, context):
    """Run certbot, write certs to SSM, and restart ECS services."""

    domain = os.environ["CONTROL_DOMAIN"]
    email = os.environ["EMAIL"]
    cluster_name = os.environ["ECS_CLUSTER_NAME"]
    service_names = [
        s for s in os.environ.get("ECS_SERVICE_NAMES", "").split(",") if s
    ]

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

    ssm = boto3.client("ssm")
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
