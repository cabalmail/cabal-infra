const AWS = require('aws-sdk');

const ddb = new AWS.DynamoDB.DocumentClient();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];
    
    listAddresses(username).then(result => {
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

function listAddresses(username) {
    return ddb.scan({
        ScanFilter: {
          "username" : {
            "AttributeValueList":[
              {"S":username}
            ],
            "ComparisonOperator": "EQ"
          }
        },
        TableName: 'cabal-addresses'
    }).promise();
}

//{
//"TableName":"cabal-addresses",
//"ReturnConsumedCapacity":"TOTAL",
//"Limit":50,
//"FilterExpression":"#n0 = :v0",
//"ExpressionAttributeNames":{"#n0":"username"},
//"ExpressionAttributeValues":{":v0":{"S":"chris"}}
//}

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
