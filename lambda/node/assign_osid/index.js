// const {
//   CognitoIdentityProviderClient,
//   ListUsersCommand,
//   AdminUpdateUserAttributesCommand
// } = require("@aws-sdk/client-cognito-identity-provider");

const AWS = require('aws-sdk');
const ddb = new AWS.DynamoDB();
  
const config = require('./config.js').config.cognitoConfig;

exports.handler = (event, context, callback) => {
  var user = event.request.userAttributes.username;
  var params = {
    TableName: 'cabal-users',
    Item: {
      username: {S: "seed"}
    },
    ExpressionAttributeValues: {
      val: {
        N: "1"
      }
    },
    UpdateExpression: "SET osid = osid + :val",
    ReturnValues: "UPDATED_NEW"
  };
  ddb.putItem(params, (err, data) => {
    if (err) {
      console.error("ddb", err);
      console.error("params", params);
    }
  })
  .then(data => {
    console.log(data);
    callback(null, event);
  })
  .catch(err => {
    console.error(err);
    callback(null, event);
  });
  // const client = new CognitoIdentityProviderClient({
  //   region: config.region
  // });
  // const ListCommand = new ListUsersCommand({
  //   UserPoolId: config.poolData.UserPoolId
  // });
  // client.send(ListCommand)
  // .then(users => {
  //   console.log(users);
  //   var uid = 2000;
  //   users.forEach(u => {
  //     u.Attributes.forEach( a => {
  //       if (a.Name == "custom:osid") {
  //         if (a.Value > uid) {
  //           uid = a.Value + 1;
  //         }
  //       }
  //     });
  //   });
  //   const UpdateCommand = new AdminUpdateUserAttributesCommand({
  //     UserPoolId: config.poolData.UserPoolId,
  //     UserAttributes: [{
  //       Name: "custom:osid",
  //       Value: uid
  //     }],
  //     Username: user
  //   });
  //   client.send(UpdateCommand)
  //   .then(data => {
  //     console.log(data);
  //     callback(null, event);
  //   })
  //   .catch(err => {
  //     console.error(err);
  //     callback(null, event);
  //   });
  // })
  // .catch(err => {
  //   console.error(err);
  //   callback(null, event);
  // });
}