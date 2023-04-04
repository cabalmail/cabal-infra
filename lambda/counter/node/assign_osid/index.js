const {
  CognitoIdentityProviderClient,
  ListUsersCommand,
  AdminUpdateUserAttributesCommand
} = require("@aws-sdk/client-cognito-identity-provider");

const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB();

const client = new CognitoIdentityProviderClient({
  region: process.env.AWS_REGION
});

const ssm = new AWS.SSM();

exports.handler = (event, context, callback) => {
  getCounter(callback, event);
}

function getCounter(callback, event) {
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
      updateUser(data.Attributes.osid.N, callback, event);
    }
  });
  return uid;
}

function updateUser(uid, callback, event) {
  const UpdateCommand = new AdminUpdateUserAttributesCommand({
    UserPoolId: event.userPoolId,
    UserAttributes: [{
      Name: "custom:osid",
      Value: uid
    }],
    Username: event.userName
  });
  client.send(UpdateCommand)
  .then(data => {
    console.log(data);
    kickOffChef(callback, event);
  })
  .catch(err => {
    console.error(err);
  });
}

function kickOffChef(callback, event) {
  const command = {
    DocumentName: 'cabal_chef_document',
    Targets: [
      { 
         "Key": "tag:managed_by_terraform",
         "Values": [ "y" ]
      },
      { 
         "Key": "tag:environment",
         "Values": [ "production" ]
      }
    ]
  };
  ssm.sendCommand(command, (err, data) => {
    if (err) {
      console.error("ssm", err);
      console.error("command", command)
    } else {
      callback(null, event);
    };
  }).promise();
}