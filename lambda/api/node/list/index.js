const { DynamoDBClient } = require("@aws-sdk/client-dynamodb");
const { DynamoDBDocumentClient, ScanCommand } = require("@aws-sdk/lib-dynamodb");

const ddb = DynamoDBDocumentClient.from(new DynamoDBClient({}));

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const user = event.requestContext.authorizer.claims['cognito:username'];
    
    listAddresses(user).then(result => {
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

function listAddresses(user) {
    const parameters = {
        "TableName": "cabal-addresses",
        "FilterExpression": "#user = :user",
        "ExpressionAttributeNames": {
            "#user": "user",
            "#c": "comment"
        },
        "ExpressionAttributeValues": {
            ":user": user
        },
        "ProjectionExpression": "subdomain, #c, tld, address, username, #user"
    };
    return ddb.send(new ScanCommand(parameters));
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
