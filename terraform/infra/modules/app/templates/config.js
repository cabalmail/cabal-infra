{
  "control_domain": "${control_domain}",
  "domains": ${jsonencode(domains)},
  "invokeUrl": "${invoke_url}",
  "cognitoConfig": {
    "region": "${region}",
    "poolData": {
      "UserPoolId": "${pool_id}",
      "ClientId": "${pool_client_id}"
    }
  }
}