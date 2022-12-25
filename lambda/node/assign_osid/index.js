const {
  CognitoIdentityProviderClient,
  ListUsersCommand,
  AdminUpdateUserAttributesCommand
} = require("@aws-sdk/client-cognito-identity-provider");

const config = require('./config.js').config.cognitoConfig;

exports.handler = (event, context, callback) => {
  var user = event.request.userAttributes.username;
  const client = new CognitoIdentityProviderClient({
    region: config.region
  });
  const ListCommand = new ListUsersCommand({
    UserPoolId: config.userPoolId
  });
  client.send(ListCommand)
  .then(users => {
    console.log(users);
    var uid = 2000;
    users.forEach(u => {
      u.Attributes.forEach( a => {
        if (a.Name == "custom:osid") {
          if (a.Value > uid) {
            uid = a.Value + 1;
          }
        }
      });
    });
    const UpdateCommand = new AdminUpdateUserAttributesCommand({
      UserPoolId: config.userPoolId,
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
  })
  .catch(err => {
    console.error(err);
    callback(null, event);
  });
}