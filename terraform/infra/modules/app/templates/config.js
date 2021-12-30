{
  "control_domain": "${control_domain}",
  "domains": ${jsonencode(domains)},
  "cognitoConfig": {
    "invokeUrl": "${invoke_url}",
    "region": "${region}",
    "poolData": {
      "UserPoolId": "${pool_id}",
      "ClientId": "${pool_client_id}"
    }
  }
}