window._config = {
    cognito: {
        userPoolId: '${pool_id}',
        userPoolClientId: '${pool_client_id}',
        region: '${region}'
    },
    api: {
        invokeUrl: '${invoke_url}'
    },
%{
  ${jsonencode({
    domains: [for domain in domains : "${domain.domain}": "${domain.zone_id}"],
  })}
~}
};

