const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, DeleteCommand } = require("@aws-sdk/lib-dynamodb");
const { Route53Client, ChangeResourceRecordSetsCommand } = require("@aws-sdk/client-route-53");

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const route53 = new Route53Client({});
const domains = JSON.parse(process.env.DOMAINS);
const control_domain = process.env.CONTROL_DOMAIN;

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];
    
    // TODO: Compare username to recorded username before allowing delete
    // TODO: Handle cases where another address shares the same subdomain

    const requestBody = JSON.parse(event.body);

    const address = requestBody.address;
    const subdomain = requestBody.subdomain;
    const tld = requestBody.tld;
    const zone_id = domains[tld];
    console.log('Received event (', address, '): ', event);

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
              "Type": "CNAME",
              "ResourceRecords": [
                {
                  Value: 'cabal._domainkey.' + control_domain
                }
              ]
            }
          },
          {
            "Action": "DELETE",
            "ResourceRecordSet": {
              "Name": '_dmarc.' + subdomain + '.' + tld,
              "TTL": 3600,
              "Type": "CNAME",
              "ResourceRecords": [
                {
                  Value: '_dmarc.' + control_domain
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

    const r53_req = route53.send(new ChangeResourceRecordSetsCommand(params));
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
    return ddb.send(new DeleteCommand({
        TableName: 'cabal-addresses',
        Key: {
            address: address,
        },
    }));
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
