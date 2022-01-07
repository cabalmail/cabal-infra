const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const r53 = new AWS.Route53();
const ssm = new AWS.SSM();
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
  const key_record = lines[1] + lines[2] + lines[3];
  const params = {
    ChangeBatch: {
    Changes: [
      {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: requestBody.subdomain + '.' + requestBody.tld,
        ResourceRecords: [
        {
          Value: '"v=spf1 include:' + control_domain + ' ~all"'
        }
        ],
        TTL: 3600,
        Type: 'TXT'
      }
      },
      {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: requestBody.subdomain + '.' + requestBody.tld,
        ResourceRecords: [
        {
          Value: '10 smtp-in.' + control_domain
        }
        ],
        TTL: 3600,
        Type: 'MX'
      }
      },
      {
      Action: "UPSERT",
      ResourceRecordSet: {
        Name: 'cabal._domainkey.' + requestBody.subdomain + '.' + requestBody.tld,
        ResourceRecords: [
        {
          Value: '"v=DKIM1; k=rsa; p=' + key_record + '"'
        }
        ],
        TTL: 3600,
        Type: 'TXT'
      }
      }
    ]
    },
    HostedZoneId: domains[requestBody.tld]
  }

  const payload = {
    user: user,
    address: requestBody.address,
    username: requestBody.username,
    zone_id: domains[requestBody.tld],
    subdomain: requestBody.subdomain,
    comment: requestBody.comment,
    tld: requestBody.tld,
    public_key: publicKey,
    private_key: privateKey
  };

  const r53_req = createDnsRecords(params);
  const dyndb_req = recordAddress(payload);
  const ssm_req = kickOffChef(repo);
  const body = JSON.stringify({
    address: requestBody.address,
    tld: requestBody.tld,
    user: requestBody.user,
    username: requestBody.username,
    "zone-id": domains[requestBody.tld],
    subdomain: requestBody.subdomain,
    comment: requestBody.comment,
    public_key: publicKey
  });

  Promise.all([r53_req, dyndb_req, ssm_req])
  .then(values => {
    callback(null, {
      statusCode: 201,
      body: body,
      headers: {
        'Access-Control-Allow-Origin': '*',
      }
    });
  })
  .catch(error => {
    console.error(error);
    callback({
      statusCode: 500,
      body: body,
      headers: {
        'Access-Control-Allow-Origin': '*',
      }
    }, null);
  });
};

function createDnsRecords(params) {
  return r53.changeResourceRecordSets(params, (err, data) => {
    if (err) {
      console.error(err);
    }
  }).promise();
}

function recordAddress(obj) {
  return ddb.put({
    TableName: 'cabal-addresses',
    Item: {
      address: obj.address,
      tld: obj.tld,
      user: obj.user,
      username: obj.username,
      "zone-id": domains[obj.tld],
      subdomain: obj.subdomain,
      comment: obj.comment,
      public_key: obj.public_key,
      private_key: obj.private_key,
      RequestTime: new Date().toISOString(),
    },
  }, (err, data) => {
    if (err) {
      console.error(err);
    }
  }).promise();
}

function kickOffChef(repo) {
  return ssm.sendCommand({
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
  }, (err, data) => {
    if (err) {
      console.error(err);
    }
  }).promise();
}