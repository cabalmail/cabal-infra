const AWS = require('aws-sdk');
const domains = JSON.parse(process.env.DOMAINS);
const control_domain = process.env.CONTROL_DOMAIN;
const addressChangedTopicArn = process.env.ADDRESS_CHANGED_TOPIC_ARN;

exports.handler = (event, context, callback) => {
  if (!event.requestContext.authorizer) {
    console.error('Authorization not configured');
    return;
  }
  const requestBody = JSON.parse(event.body);
  const user = event.requestContext.authorizer.claims['cognito:username'];
  const r53_params = buildR53Params(
    domains[requestBody.tld],
    requestBody.subdomain,
    requestBody.tld,
    control_domain
  );
  const dyndb_payload = {
    user: user,
    address: requestBody.address,
    username: requestBody.username,
    zone_id: domains[requestBody.tld],
    subdomain: requestBody.subdomain,
    comment: requestBody.comment,
    tld: requestBody.tld
  };

  const r53_req = createDnsRecords(r53_params);
  const dyndb_req = recordAddress(dyndb_payload);
  const ssm_req = kickOffChef();
  const sns_req = notifyContainers();
  Promise.all([r53_req, dyndb_req, ssm_req, sns_req])
  .then(values => {
    console.log("Success. Invoking callback.");
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

function changeItem(name, value, type) {
  return {
    Action: "UPSERT",
    ResourceRecordSet: {
      Name: name,
      ResourceRecords: [
        {
          Value: value
        }
      ],
      TTL: 3600,
      Type: type
    }
  };
}

function buildR53Params(zone_id, subdomain, tld, control_domain) {
  let r53_params = {
    ChangeBatch: {
      Changes: []
    },
    HostedZoneId: zone_id
  };

  r53_params.ChangeBatch.Changes.push(changeItem(
    '_dmarc.' + subdomain + '.' + tld,
    '_dmarc.' + control_domain,
    'CNAME'
  ));

  r53_params.ChangeBatch.Changes.push(changeItem(
    subdomain + '.' + tld,
    '"v=spf1 include:' + control_domain + ' ~all"',
    'TXT'
  ));

  r53_params.ChangeBatch.Changes.push(changeItem(
    subdomain + '.' + tld,
    '10 smtp-in.' + control_domain,
    'MX'
  ));

  r53_params.ChangeBatch.Changes.push(changeItem(
    'cabal._domainkey.' + subdomain + '.' + tld,
    'cabal._domainkey.' + control_domain,
    'CNAME'
  ));

  return r53_params;
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