#!/bin/bash
cd ./lambda/counter/node
FUNCTIONS=$(echo *)
AWS_S3_BUCKET="admin.$(aws ssm get-parameter --name '/cabal/control_domain_zone_name' --profile deploy_lambda | jq -r '.Parameter.Value')"
FUNC=assign_osid
pushd $FUNC
if test -f requirements.txt; then
  mkdir nodejs
  pushd nodejs
  npm init --yes
  cat ../requirements.txt | xargs npm install --save 
  popd
fi
zip -r ../$FUNC.zip .
popd
openssl dgst -sha256 -binary "$FUNC.zip" | openssl enc -base64 | tr -d "\n" > "$FUNC.zip.base64sha256"
aws s3 cp "$FUNC.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/$FUNC.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain
aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private
