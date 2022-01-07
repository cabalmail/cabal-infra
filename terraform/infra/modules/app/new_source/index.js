const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const r53 = new AWS.Route53();
const ssm = new AWS.SSM();
const control_domain = "${control_domain}";
const repo = "${repo}";
const domains = ${jsonencode(domains)};

exports.handler = async (event, context) => {
    if (!event.requestContext.authorizer) {
      console.error('Authorization not configured');
      errorResponse('Authorization not configured', context.awsRequestId);
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

    const r53_req = await createDnsRecords(params).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId);
    });

    const dyndb_req = await recordAddress(payload).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId);
    });

    const ssm_req = await kickOffChef(repo).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId);
    });
    
    try {
        let res = await Promise.all([r53_req, dyndb_req, ssm_req]).then(values => {
            console.log(values);
            return {
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
            };
        });
        return res;
    } catch (err) {
        console.error(err);
        return {
            statusCode: 500,
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
        };
    }
};

function createDnsRecords(params) {
    return r53.changeResourceRecordSets(params, function(err, data) {
        if (err) {
            console.error(err);
        } else {
            console.log("route 53 success", data);
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
        } else {
            console.log("dynamodb success", data);
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
            console.log(err, err.stack);
          } else {
              console.log("ssm success", data);
        }
    }).promise();
}

function toUrlString(buffer) {
    return buffer.toString('base64')
        .replace(/\+/g, '-')
        .replace(/\//g, '_')
        .replace(/=/g, '');
}