#!/bin/bash

OUT=/usr/bin/cognito.bash

echo "#!/bin/bash" >$OUT
echo >> $OUT
echo 'COGNITO_PASSWORD=`cat -`' >>$OUT
echo 'COGNITO_USER="${PAM_USER}"' >>$OUT
echo 'AUTH_TYPE="${PAM_TYPE}"' >>$OUT
echo >> $OUT
echo 'aws cognito-idp initiate-auth \' >>$OUT
echo "  --region ${REGION} \\" >>$OUT
echo '  --auth-flow USER_PASSWORD_AUTH \' >> $OUT
echo "  --client-id $CLIENT_ID \\" >>$OUT
echo '  --auth-parameters "USERNAME=${COGNITO_USER},PASSWORD=\"${COGNITO_PASSWORD}\""' >>$OUT
chmod 0100 $OUT
cat $OUT



#    # Chef
#    #!/bin/bash
#    
#    COGNITO_PASSWORD=`cat -`
#    COGNITO_USER="${PAM_USER}"
#    AUTH_TYPE="${PAM_TYPE}"
#    
#    aws cognito-idp initiate-auth \
#      --region <%=@region%> \
#      --auth-flow USER_PASSWORD_AUTH \
#      --client-id <%=@client_id%> \
#      --auth-parameters "USERNAME=${COGNITO_USER},PASSWORD=\"${COGNITO_PASSWORD}\""
#    
#    
#    
#    
#    # As installed
#    #!/bin/bash
#    
#    COGNITO_PASSWORD=`cat -`
#    COGNITO_USER="${PAM_USER}"
#    AUTH_TYPE="${PAM_TYPE}"
#    
#    aws cognito-idp initiate-auth \
#      --region us-east-1 \
#      --auth-flow USER_PASSWORD_AUTH \
#      --client-id 743i00o1249kvehqsilulsonlj \
#      --auth-parameters "USERNAME=${COGNITO_USER},PASSWORD=\"${COGNITO_PASSWORD}\""
