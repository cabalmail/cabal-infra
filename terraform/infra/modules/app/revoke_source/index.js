const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const route53 = new AWS.Route53();
// following two lines expanded by Terraform template
const control_domain = "${control_domain}";
const domains = ${jsonencode(domains)};

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
    revokeAddress(address).then(v => {
      var params = {
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
                    Value: '"' + publicKeyFlattened + '"'
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

      route53.changeResourceRecordSets(params, function(err,data) {
        console.log(err,data);
      });
      callback(null, {
          statusCode: 202,
          body: JSON.stringify({
            "status": "success",
            "address": address
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
