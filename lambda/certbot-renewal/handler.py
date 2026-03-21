"""Lambda handler that renews Let's Encrypt certificates using certbot
and stores them in SSM Parameter Store."""

import json
import os
import subprocess

import boto3


SSM_PATHS = {
    "privkey": "/cabal/control_domain_ssl_key",
    "cert": "/cabal/control_domain_ssl_cert",
    "chain": "/cabal/control_domain_chain_cert",
}


def handler(event, context):
    """Run certbot, write certs to SSM, and restart ECS services."""

    domain = os.environ["CONTROL_DOMAIN"]
    email = os.environ["EMAIL"]
    use_staging = os.environ.get("USE_STAGING", "true").lower() == "true"
    cluster_name = os.environ["ECS_CLUSTER_NAME"]
    service_names = [
        s for s in os.environ.get("ECS_SERVICE_NAMES", "").split(",") if s
    ]

    # Run certbot
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
    if use_staging:
        cmd.append("--staging")

    print(f"Running certbot for *.{domain} (staging={use_staging})")
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

    return {
        "statusCode": 200,
        "body": json.dumps({"message": "Certificate renewed successfully"}),
    }
