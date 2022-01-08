const AWS = require('aws-sdk');
const control_domain = "${control_domain}";
const repo = "${repo}";
const domains = ${jsonencode(domains)};

exports.handler = (event, context, callback) => {
  if (!event.requestContext.authorizer) {
    console.error('Authorization not configured');
    return;
  }
  const requestBody = JSON.parse(event.body);
  const user = event.requestContext.authorizer.claims['cognito:username'];
  const key = generateKeyPair();
  const r53_params = buildR53Params(
    domains[requestBody.tld],
    requestBody.subdomain,
    requestBody.tld,
    control_domain,
    key.publicKeyFlattened
  );
  const dyndb_payload = {
    user: user,
    address: requestBody.address,
    username: requestBody.username,
    zone_id: domains[requestBody.tld],
    subdomain: requestBody.subdomain,
    comment: requestBody.comment,
    tld: requestBody.tld,
    public_key: key.publicKey,
    private_key: key.privateKey
  };

  const r53_req = createDnsRecords(r53_params);
  const dyndb_req = recordAddress(dyndb_payload);
  const ssm_req = kickOffChef(repo);
  Promise.all([r53_req, dyndb_req, ssm_req])
  .then(values => {
    callback(null, generateResponse(201, values, requestBody.address));
  }, reason => {
    console.error("rejected", reason);
    throw "Rejected";
  })
  .catch(error => {
    console.error("caught", error);
    callback(generateResponse(500, error, requestBody.address), null);
  });
};

function createDnsRecords(params) {
  const r53 = new AWS.Route53();
  return r53.changeResourceRecordSets(params, (err, data) => {
    if (err) {
      console.error("r53", err);
      console.error("params", params)
    }
  }).promise();
}

function recordAddress(obj) {
  const ddb = new AWS.DynamoDB();
  const params = {
    TableName: 'cabal-addresses',
    Item: {
      address: { S: obj.address },
      tld: { S: obj.tld },
      user: { S: obj.user },
      username: { S: obj.username },
      "zone-id": { S: domains[obj.tld] },
      subdomain: { S: obj.subdomain },
      comment: { S: obj.comment || '' },
      public_key: { S: obj.public_key },
      private_key: { S: obj.private_key },
      RequestTime: { S: new Date().toISOString() },
    },
  };
  return ddb.putItem(params, (err, data) => {
    if (err) {
      console.error("ddb", err);
      console.error("params", params);
    }
  }).promise();
}

function kickOffChef(repo) {
  const ssm = new AWS.SSM();
  const command = {
    DocumentName: 'cabal_chef_document',
    Targets: [
      { 
         "Key": "tag:managed_by_terraform",
         "Values": [ "y" ]
      },
      { 
         "Key": "tag:terraform_repo",
         "Values": [ repo ]
      }
    ]
  };
  return ssm.sendCommand(command, (err, data) => {
    if (err) {
      console.error("ssm", err);
      console.error("command", command)
    }
  }).promise();
}

function buildR53Params(zone_id, subdomain, tld, control_domain, key_record) {
  let r53_params = {
    ChangeBatch: {
      Changes: []
    },
    HostedZoneId: zone_id
  };

  r53_params.ChangeBatch.Changes.push(
    {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: subdomain + '.' + tld,
        ResourceRecords: [
          {
            Value: '"v=spf1 include:' + control_domain + ' ~all"'
          }
        ],
        TTL: 3600,
        Type: 'TXT'
      }
    }
  );

  r53_params.ChangeBatch.Changes.push(
    {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: subdomain + '.' + tld,
        ResourceRecords: [
          {
            Value: '10 smtp-in.' + control_domain
          }
        ],
        TTL: 3600,
        Type: 'MX'
      }
    }
  );

  r53_params.ChangeBatch.Changes.push(
    {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: 'cabal._domainkey.' + subdomain + '.' + tld,
        ResourceRecords: [
          {
            Value: '"v=DKIM1; k=rsa; p=' + key_record + '"'
          }
        ],
        TTL: 3600,
        Type: 'TXT'
      }
    }
  );
  
  return r53_params;
}

function generateKeyPair() {
  const { generateKeyPairSync } = require('crypto');
  const { publicKey, privateKey } = generateKeyPairSync('rsa', {
    modulusLength: 1024,
    publicKeyEncoding: {
      type: 'pkcs1',
      format: 'pem'
    },
    privateKeyEncoding: {
      type: 'pkcs1',
      format: 'pem'
    }
  });
  const lines = publicKey.split(/\r?\n/);
  const publicKeyFlattened = lines[1] + lines[2] + lines[3];
  return {
    publicKey: publicKey,
    privateKey: privateKey,
    publicKeyFlattened: publicKeyFlattened
  };
}

function generateBody(data, address) {
  return JSON.stringify({
    address: address,
    data: data
  });
}

function generateResponse(status, data, address) {
  return {
    statusCode: status,
    body: generateBody(data, address),
    headers: {
      'Access-Control-Allow-Origin': '*',
    }
  };
} 