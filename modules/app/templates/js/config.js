window._config = {
    cognito: {
        userPoolId: '${pool_id}',
        userPoolClientId: '${pool_client_id}',
        region: '${region}'
    },
    api: {
        invokeUrl: '${invoke_url}'
    },
    domains: [
%{ for domain in domains ~}
      {}
%{ endfor ~}
    ]
};

