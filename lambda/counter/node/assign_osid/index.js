const {
  CognitoIdentityProviderClient,
  AdminUpdateUserAttributesCommand
} = require("@aws-sdk/client-cognito-identity-provider");
const { DynamoDBClient, UpdateItemCommand } = require("@aws-sdk/client-dynamodb");
const { SSMClient, SendCommandCommand } = require("@aws-sdk/client-ssm");

const region = process.env.AWS_REGION;
const client = new CognitoIdentityProviderClient({ region });
const ddb = new DynamoDBClient({ region });
const ssm = new SSMClient({ region });

exports.handler = async (event, context, callback) => {
  await getCounter(callback, event);
}

async function getCounter(callback, event) {
  const params = {
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
  try {
    const data = await ddb.send(new UpdateItemCommand(params));
    await updateUser(data.Attributes.osid.N, callback, event);
  } catch (err) {
    console.error("ddb", err);
    console.error("params", params);
    callback(err);
  }
}

async function updateUser(uid, callback, event) {
  const command = new AdminUpdateUserAttributesCommand({
    UserPoolId: event.userPoolId,
    UserAttributes: [{
      Name: "custom:osid",
      Value: uid
    }],
    Username: event.userName
  });
  const data = await client.send(command);
  console.log(data);
  await kickOffChef(callback, event);
}

async function kickOffChef(callback, event) {
  const params = {
    DocumentName: 'cabal_chef_document',
    Targets: [
      {
         "Key": "tag:managed_by_terraform",
         "Values": [ "y" ]
      }
    ]
  };
  try {
    await ssm.send(new SendCommandCommand(params));
    callback(null, event);
  } catch (err) {
    console.error("ssm", err);
    console.error("command", params);
    callback(err);
  }
}
