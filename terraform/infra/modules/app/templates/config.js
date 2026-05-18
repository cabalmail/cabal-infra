{
  "control_domain": "${control_domain}",
  "domains": ${jsonencode(domains)},
  "invokeUrl": "${invoke_url}",
  "invitation_required": ${jsonencode(invitation_required)},
  "cognitoConfig": {
    "region": "${region}",
    "poolData": {
      "UserPoolId": "${pool_id}",
      "ClientId": "${pool_client_id}"
    }
  }
}