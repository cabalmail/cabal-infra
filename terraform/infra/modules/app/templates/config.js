const control_domain = "${control_domain}";
const domains = ${jsonencode(domains)};
const cognitoConfig = {
  invokeUrl: "${invoke_url}",
  region: "${region}",
  poolData = {
    UserPoolId: "${pool_id}",
    ClientId: "${pool_client_id}"
  }
};