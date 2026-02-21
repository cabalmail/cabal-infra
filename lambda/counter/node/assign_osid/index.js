const {
  CognitoIdentityProviderClient,
  ListUsersCommand,
  AdminUpdateUserAttributesCommand
} = require("@aws-sdk/client-cognito-identity-provider");

const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { SSMClient, SendCommandCommand } = require("@aws-sdk/client-ssm");
const { ECSClient, UpdateServiceCommand } = require("@aws-sdk/client-ecs");

const region = process.env.AWS_REGION;

const client = new CognitoIdentityProviderClient({ region });
const ddb = new DynamoDBClient({ region });
const ssm = new SSMClient({ region });
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
  ddb.send(new UpdateItemCommand(params))
  .then(data => {
    updateUser(data.Attributes.osid.N, callback, event);
  })
  .catch(err => {
    console.error("ddb", err);
    console.error("params", params);
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
  return ssm.send(new SendCommandCommand(command))
  .catch(err => {
    console.error("ssm", err);
    console.error("command", command);
  });
}

function refreshContainers() {
  if (!ecsClusterName) {
    console.log("ECS_CLUSTER_NAME not set, skipping ECS service update");
    return Promise.resolve();
  }
  const ecs = new ECSClient({ region });
  const services = ['cabal-imap', 'cabal-smtp-in', 'cabal-smtp-out'];
  return Promise.all(services.map(service => {
    return ecs.send(new UpdateServiceCommand({
      cluster: ecsClusterName,
      service: service,
      forceNewDeployment: true
    })).catch(err => {
      console.error("ecs updateService error for " + service, err);
    });
  }));
}
