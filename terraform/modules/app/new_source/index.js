const AWS = require('aws-sdk');

const ddb = new AWS.DynamoDB.DocumentClient();
const r53 = new AWS.Route53();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      console.error('Authorization not configured');
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }
    console.log('Received event (', requestBody.address, '): ', event);
    const control_domain = event.headers['X-Control-Domain'];
    const eips = event.headers['X-Egress-IPs'];
    const user = event.requestContext.authorizer.claims['cognito:username'];
    const requestBody = JSON.parse(event.body);
    var public_key;
    var private_key;
    const { generateKeyPair } = require('crypto');
    generateKeyPair('rsa', {
      modulusLength: 1024,
      publicKeyEncoding: {
        type: 'pkcs1',
        format: 'pem'
      },
      privateKeyEncoding: {
        type: 'pkcs1',
        format: 'pem'
      }
    }, (err, public_key, private_key) => {
      if (err) {
        console.error(err);
      }
      public_key = public_key;
      private_key = private_key;
    });

    var params = {
      ChangeBatch: {
        Changes: [
          {
            Action: "UPSERT",
            ResourceRecordSet: {
              Name: requestBody.subdomain + '.' + requestBody.tld,
              ResourceRecords: [
                {
                  Value: "v=spf1 " + eips
                }
              ],
              TTL: 360,
              Type: 'TXT'
            }
          },
          {
            Action: "UPSERT",
            ResourceRecordSet: {
              Name: requestBody.subdomain + '.' + requestBody.tld,
              ResourceRecords: [
                {
                  Value: "1 smtp-in." + control_domain
                }
              ],
              TTL: 360,
              Type: 'MX'
            }
          },
          {
            Action: "UPSERT",
            ResourceRecordSet: {
              Name: 'cabal._domainkey.' + requestBody.subdomain + '.' + requestBody.tld,
              ResourceRecords: [
                {
                  Value: "v=DKIM1; k=rsa; p=" + public_key
                }
              ],
              TTL: 360,
              Type: 'TXT'
            }
          }
        ]
      },
      HostedZone: requestBody.zone_id
    }
    r53.changeResourceRecordSets(params, function(err, data) {
      
    });
    const payload = {
      user: user,
      address: requestBody.address,
      username: requestBody.username;
      zone_id: requestBody.zone_id;
      subdomain: requestBody.subdomain;
      comment: requestBody.comment;
      tld: requestBody.tld;
    };

    recordAddress(payload).then(() => {
        callback(null, {
            statusCode: 201,
            body: JSON.stringify({
                address: requestBody.address,
                tld: requestBody.tld,
                user: requestBody.user,
                username: requestBody.username,
                "zone-id": requestBody.zone_id,
                subdomain: requestBody.subdomain,
                comment: requestBody.comment,
                public_key: public_key
            }),
            headers: {
                'Access-Control-Allow-Origin': '*',
            },
        });
    }).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId, callback)
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
            "zone-id": obj.zone_id,
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
