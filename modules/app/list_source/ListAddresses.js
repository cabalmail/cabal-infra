const AWS = require('aws-sdk');

const ddb = new AWS.DynamoDB.DocumentClient();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];

    const tlds = {
      "Z2GS79AAMTQXNV": "randomsound.org",
      "ZBYS915K03BC2": "cathycarr.org",
      "Z33IB65UD0QYKU": "hackthumb.com",
      "Z2UFK0POOZL6IV": "ccarr.com",
      "Z1FO2MQJDQEPLA": "cabalmail.com",
      "Z1YIW2SGWFY5A7": "chriscarr.org",
      "Z1H7RU5O7WHDJH": "constancedu.com",
      "Z1U9GPZMPLPCS7": "depre.world",
    }

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

    listAddresses().then(result => {
        callback(null, {
            statusCode: 200,
            headers: {
                'Access-Control-Allow-Origin': '*',
                'Access-Control-Allow-Credentials' : true
            },
            body: JSON.stringify(result),
        });
    }).catch((err) => {
        console.error(err);
        errorResponse(err.message, context.awsRequestId, callback)
    });
};

function listAddresses() {
    return ddb.scan({
        TableName: 'cabal-addresses'
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
      'Access-Control-Allow-Methods': 'GET, OPTIONS',
    },
  });
}
