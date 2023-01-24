const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const route53 = new AWS.Route53();
const domains = JSON.parse(process.env.DOMAINS);
const control_domain = process.env.CONTROL_DOMAIN;

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];
    
    // TODO: Compare username to recorded username before allowing delete

    const requestBody = JSON.parse(event.body);

    const address = requestBody.address;
    const subdomain = requestBody.subdomain;
    const tld = requestBody.tld;
    const zone_id = domains[tld];
    const public_key = requestBody.public_key;
    console.log('Received event (', address, '): ', event);

    const lines = public_key.split(/\r?\n/);
    const publicKeyFlattened = lines[1] + lines[2] + lines[3];
    const params = {
      "HostedZoneId": zone_id,
      "ChangeBatch": {
        "Changes": [
          {
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": subdomain + '.' + tld,
              "TTL": 3600,
              "Type": "MX",
              "ResourceRecords": [
                {
                  Value: '10 smtp-in.' + control_domain
                }
              ]
            }
          },
          {
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": 'cabal._domainkey.' + subdomain + '.' + tld,
              "TTL": 3600,
              "Type": "TXT",
              "ResourceRecords": [
                {
                  Value: '"v=DKIM1; k=rsa; p=' + publicKeyFlattened + '"'
                }
              ]
            }
          },
          {
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": subdomain + '.' + tld,
              "TTL": 3600,
              "Type": "TXT",
              "ResourceRecords": [
                {
                  Value: '"v=spf1 include:' + control_domain + ' ~all"'
                }
              ]
            }
          }
        ]
      }
    };

    const r53_req = route53.changeResourceRecordSets(params, function(err,data) {
      if (err) {
        console.error("r53 error", err);
        errorResponse(err, context.awsRequestId, callback);
      }
    }).promise();
    const ddb_req = revokeAddress(address);
    Promise.all([ddb_req, r53_req]).then(values => {
      callback(null, {
        statusCode: 202,
        body: JSON.stringify({
          "status": "success",
          "address": address
        }),
        headers: {
            'Access-Control-Allow-Origin': '*',
        },
      }, reason => {
        console.error("rejected", reason);
        throw "Rejected";
      });
    }).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId, callback);
    });
};

function revokeAddress(address, zone_id, subdomain) {
    return ddb.delete({
        TableName: 'cabal-addresses',
        Key: {
            address: address,
        },
    }).promise();
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
