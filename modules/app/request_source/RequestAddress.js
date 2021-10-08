const AWS = require('aws-sdk');

const ddb = new AWS.DynamoDB.DocumentClient();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];

    const requestBody = JSON.parse(event.body);

    const address = requestBody.address;
    const user = requestBody.user;
    const cabalusername = requestBody.cabalusername;
    const zone_id = requestBody.zone_id;
    const subdomain = requestBody.subdomain;
    const comment = requestBody.comment;
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

    const allowedZones = {
      "leader@admin.cabalmail.com": {
        "Z2GS79AAMTQXNV": true,
        "ZBYS915K03BC2": true,
        "Z33IB65UD0QYKU": true,
        "Z2UFK0POOZL6IV": true,
        "Z1FO2MQJDQEPLA": true,
        "Z1YIW2SGWFY5A7": true,
        "Z1H7RU5O7WHDJH": true,
        "Z1U9GPZMPLPCS7": true,
      },
    }

    console.log('Received event (', address, '): ', event);

    recordAddress(address, user, cabalusername, zone_id, subdomain, comment, tlds).then(() => {
        callback(null, {
            statusCode: 201,
            body: JSON.stringify({
                address: address,
                tld: tlds[zone_id],
                user: user,
                username: cabalusername,
                "zone-id": zone_id,
                subdomain: subdomain,
                comment: comment,
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

function recordAddress(address, user, cabalusername, zone_id, subdomain, comment, tlds) {
    return ddb.put({
        TableName: 'cabal-addresses',
        Item: {
            address: address,
            tld: tlds[zone_id],
            user: user,
            username: cabalusername,
            "zone-id": zone_id,
            subdomain: subdomain,
            comment: comment,
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
