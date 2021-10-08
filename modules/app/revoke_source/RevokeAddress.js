const { promisify } = require('util');
const dnsCallback = require('dns');
const dns = promisify(dnsCallback.resolve);
const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const route53 = new AWS.Route53();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];

    const requestBody = JSON.parse(event.body);

    const address = requestBody.address;
    const subdomain = requestBody.subdomain;
    const zone_id = requestBody.zone_id;
    const tlds = {
      "Z2GS79AAMTQXNV": "randomsound.org",
      "ZBYS915K03BC2": "cathycarr.org",
      "Z33IB65UD0QYKU": "hackthumb.com",
      "Z2UFK0POOZL6IV": "ccarr.com",
      "Z1FO2MQJDQEPLA": "cabalmail.com",
      "Z1YIW2SGWFY5A7": "chriscarr.org",
      "Z1H7RU5O7WHDJH": "constancedu.com",
      "Z1U9GPZMPLPCS7": "depre.world",
    };
    const tld = tlds[zone_id];
    console.log('Received event (', address, '): ', event);

    var promise1 = revokeAddress(address);
    var promise2 = dns(subdomain + '.' + tld, 'MX');
    var promise3 = dns('services._domainkey.' + subdomain + '.' + tld, 'TXT');
    var promise4 = dns(subdomain + '.' + tld, 'TXT');

    Promise.all([promise1, promise2, promise3, promise4]).then(values => {
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
                    "Value": values[1][1].priority + ' ' + values[1][1].exchange
                  },
                  {
                    "Value": values[1][0].priority + ' ' + values[1][0].exchange
                  }
                ],
              }
            },
            {
              "Action": "DELETE",
              "ResourceRecordSet": {
                "Name": 'services._domainkey.' + subdomain + '.' + tld,
                "TTL": 3600,
                "Type": "TXT",
                "ResourceRecords":  values[2].map(v => {
                  return { Value: '"' + v[0] + '"' };
                }),
              }
            },
            {
              "Action": "DELETE",
              "ResourceRecordSet": {
                "Name": subdomain + '.' + tld,
                "TTL": 3600,
                "Type": "TXT",
                "ResourceRecords":  values[3].map(v => {
                  return { Value: '"' + v[0] + '"' };
                }),
              }
            }
          ]
        }
      };

      route53.changeResourceRecordSets(params, function(err,data) {
        console.log(err,data);
      });
        callback(null, {
            statusCode: 201,
            body: '{"status":"success"}',
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
