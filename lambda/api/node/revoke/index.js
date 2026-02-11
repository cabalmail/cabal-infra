const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB.DocumentClient();
const route53 = new AWS.Route53();
const domains = JSON.parse(process.env.DOMAINS);
const control_domain = process.env.CONTROL_DOMAIN;
const addressChangedTopicArn = process.env.ADDRESS_CHANGED_TOPIC_ARN;

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

    const r53_req = route53.changeResourceRecordSets(params, function(err,data) {
      if (err) {
        console.error("r53 error", err);
        errorResponse(err, context.awsRequestId, callback);
      }
    }).promise();
    const ddb_req = revokeAddress(address);
    const ssm_req = kickOffChef();
    const sns_req = notifyContainers();
    Promise.all([ddb_req, r53_req, ssm_req, sns_req]).then(values => {
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

function kickOffChef() {
  const ssm = new AWS.SSM();
  const command = {
    DocumentName: 'cabal_chef_document',
    Targets: [
      {
         "Key": "tag:managed_by_terraform",
         "Values": [ "y" ]
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

function notifyContainers() {
  if (!addressChangedTopicArn) {
    console.log("ADDRESS_CHANGED_TOPIC_ARN not set, skipping SNS publish");
    return Promise.resolve();
  }
  const sns = new AWS.SNS();
  const params = {
    TopicArn: addressChangedTopicArn,
    Message: JSON.stringify({
      event: "address_changed",
      timestamp: new Date().toISOString()
    })
  };
  return sns.publish(params, (err, data) => {
    if (err) {
      console.error("sns", err);
      console.error("params", params);
    }
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
