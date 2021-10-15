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
    const zone_id = requestBody.zone_id;
    const subdomain = requestBody.subdomain;
    const comment = requestBody.comment;
    const tld = requestBody.tld
    console.log('Received event (', address, '): ', event);

    recordAddress(username, address, user, zone_id, subdomain, comment, tld).then(() => {
        callback(null, {
            statusCode: 201,
            body: JSON.stringify({
                address: address,
                tld: tld,
                user: user,
                username: username,
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

function recordAddress(username, address, user, zone_id, subdomain, comment, tld) {
    return ddb.put({
        TableName: 'cabal-addresses',
        Item: {
            address: address,
            tld: tld,
            user: user,
            username: username,
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
