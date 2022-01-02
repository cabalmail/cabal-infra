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
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }
    const requestBody = JSON.parse(event.body);
    console.log('Received event (', requestBody.address, '): ', event);
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
    var params = {
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
    r53.changeResourceRecordSets(params, function(err, data) {
      if (err) {
        console.error(err);
      }
    });
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

    
    recordAddress(payload).then(() => {
        ssm.sendCommand({
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
        }, function(err, data) {
            if (err) {
                console.log(err, err.stack);
                errorResponse(err.message, context.awsRequestId, callback);
            } else {
                callback(null, {
                    statusCode: 201,
                    body: JSON.stringify({
                        address: requestBody.address,
                        tld: requestBody.tld,
                        user: requestBody.user,
                        username: requestBody.username,
                        "zone-id": domains[requestBody.tld],
                        subdomain: requestBody.subdomain,
                        comment: requestBody.comment,
                        public_key: publicKey
                    }),
                    headers: {
                        'Access-Control-Allow-Origin': '*',
                    },
                });
                console.log(data);
            }
        });
    }).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId, callback);
    });
  };

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
    }).promise();
}

function toUrlString(buffer) {
    return buffer.toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=/g, '');
}

function errorResponse(errorMessage, awsRequestId, callback) {
  callback(null, {
    statusCode: 500,
    body: JSON.stringify({
      Error: errorMessage,
      Reference: awsRequestId,
    }),
    headers: {
      'Access-Control-Allow-Origin': '*',
    },
  });
}
