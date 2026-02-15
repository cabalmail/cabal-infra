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
const ecsClusterName = process.env.ECS_CLUSTER_NAME;

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
    onUserCreated(callback, event);
  })
  .catch(err => {
    console.error(err);
  });
}

function onUserCreated(callback, event) {
  const chefPromise = kickOffChef();
  const ecsPromise = refreshContainers();
  Promise.all([chefPromise, ecsPromise])
  .then(() => {
    callback(null, event);
  })
  .catch(err => {
    console.error("post-user-creation error", err);
    callback(null, event);
  });
}

function kickOffChef() {
  const command = {
    DocumentName: 'cabal_chef_document',
    Targets: [
      {
         "Key": "tag:managed_by_terraform",
         "Values": [ "y" ]
      }
    ]
  };
  return ssm.sendCommand(command, (err, data) => {
    if (err) {
      console.error("ssm", err);
      console.error("command", command)
    }
  }).promise();
}

function refreshContainers() {
  if (!ecsClusterName) {
    console.log("ECS_CLUSTER_NAME not set, skipping ECS service update");
    return Promise.resolve();
  }
  const ecs = new AWS.ECS();
  const services = ['cabal-imap', 'cabal-smtp-in', 'cabal-smtp-out'];
  return Promise.all(services.map(service => {
    return ecs.updateService({
      cluster: ecsClusterName,
      service: service,
      forceNewDeployment: true
    }).promise().catch(err => {
      console.error("ecs updateService error for " + service, err);
    });
  }));
}
