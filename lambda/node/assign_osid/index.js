const {
  CognitoIdentityProviderClient,
  ListUsersCommand,
  AdminUpdateUserAttributesCommand
} = require("@aws-sdk/client-cognito-identity-provider");

const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB();

const config = require('./config.js').config.cognitoConfig;
const client = new CognitoIdentityProviderClient({
  region: config.region
});

exports.handler = (event, context, callback) => {
  getCounter(event.userName, callback, event);
}

function getCounter(user, callback, event) {
  var uid;
  var params = {
    TableName: 'cabal-counter',
    Key: {
      counter: {S: "counter"}
    },
    ExpressionAttributeValues: {
      ":val": {
        N: "1"
      }
    },
    UpdateExpression: "SET osid = osid + :val",
    ReturnValues: "UPDATED_NEW"
  };
  ddb.updateItem(params, (err, data) => {
    if (err) {
      console.error("ddb", err);
      console.error("params", params);
    } else {
      updateUser(user, data.Attributes.osid.N, callback, event);
    }
  });
  return uid;
}

function updateUser(user, uid, callback, event) {
  const UpdateCommand = new AdminUpdateUserAttributesCommand({
    UserPoolId: config.poolData.UserPoolId,
    UserAttributes: [{
      Name: "custom:osid",
      Value: uid
    }],
    Username: user
  });
  client.send(UpdateCommand)
  .then(data => {
    console.log(data);
    callback(null, event);
  })
  .catch(err => {
    console.error(err);
    callback(null, event);
  });
}