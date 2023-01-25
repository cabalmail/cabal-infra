'''Creates a new email address'''
import json
import boto3
import botocore
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization

def handler(event, _context):
    '''Creates a new email address'''
    body = json.loads(event['body'])
    user = event['requestContext']['authorizer']['claims']['cognito:username'];

    data = client.list_hosted_zones()
    domains = map(extractDomains, data.HostedZones)
    key = generateKeyPair()
    r53_params = buildR53Params(
        domains[requestBody['tld']],
        requestBody['subdomain'],
        requestBody['tld'],
        control_domain, # need to define this
        key.publicKeyFlattened
    );



    return {
        "statusCode": 201,
        "body": json.dumps(response)
    }

def extractDomains(domain):
    return {domain.Name: domain.Id}

def generateKeyPair():
    private_key = rsa.generate_private_key(
        public_exponent=65537,
        key_size=1024
    )
    pem_private_key = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS1,
        encryption_algorithm=serialization.NoEncryption()
    )
    pem_public_key = private_key.public_key().public_bytes(
      encoding=serialization.Encoding.PEM,
      format=serialization.PublicFormat.SubjectPublicKeyInfo
    )
    flattened_public_key = f"{pem_public_key.splitlines()[1]}{pem_public_key.splitlines()[2]}{pem_public_key.splitlines()[3]}"
    return {
        privateKey: pem_private_key,
        publicKey: pem_public_key,
        publicKeyFlattened: flattened_public_key
    }
