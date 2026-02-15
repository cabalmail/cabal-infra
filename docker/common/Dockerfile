FROM library/amazonlinux
ARG REGION=us-east-1
ARG CLIENT_ID
ADD --chown=root:root --chmod=0700 ./create_cognito.bash.bash /tmp/create_cognito.bash.bash
CMD /tmp/create_cognito.bash.bash
