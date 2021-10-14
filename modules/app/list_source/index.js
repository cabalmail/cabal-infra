const AWS = require('aws-sdk');

const ddb = new AWS.DynamoDB.DocumentClient();

exports.handler = (event, context, callback) => {
    if (!event.requestContext.authorizer) {
      errorResponse('Authorization not configured', context.awsRequestId, callback);
      return;
    }

    const username = event.requestContext.authorizer.claims['cognito:username'];
    
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
  //   const params = {
  //   // Specify which items in the results are returned.
  //   FilterExpression: "Subtitle = :topic AND Season = :s AND Episode = :e",
  //   // Define the expression attribute value, which are substitutes for the values you want to compare.
  //   ExpressionAttributeValues: {
  //     ":topic": {S: "SubTitle2"},
  //     ":s": {N: 1},
  //     ":e": {N: 2},
  //   },
  //   // Set the projection expression, which are the attributes that you want.
  //   ProjectionExpression: "Season, Episode, Title, Subtitle",
  //   TableName: "EPISODES_TABLE",
  // };
  
  // ddb.scan(params, function (err, data) {
  //   if (err) {
  //     console.log("Error", err);
  //   } else {
  //     console.log("Success", data);
  //     data.Items.forEach(function (element, index, array) {
  //       console.log(
  //           "printing",
  //           element.Title.S + " (" + element.Subtitle.S + ")"
  //       );
  //     });
  //   }
  // });
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
