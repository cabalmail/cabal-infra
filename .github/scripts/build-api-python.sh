#!/bin/bash
cd ./lambda/api/python
AWS_S3_BUCKET="admin.$(aws ssm get-parameter --name '/cabal/control_domain_zone_name' --profile deploy_lambda | jq -r '.Parameter.Value')"
for FUNC in * ; do
  pushd "${FUNC}"
  pip install -r requirements.txt -t ./python 2>/dev/null || true
  find . -exec touch -d "2004-02-29 16:21:42" \{\} \; -print | sort | zip -X -D ../$FUNC.zip -@
  popd
  openssl dgst -sha256 -binary "$FUNC.zip" | openssl enc -base64 | tr -d "\n" > "$FUNC.zip.base64sha256"
  aws s3 cp "$FUNC.zip.base64sha256" "s3://${AWS_S3_BUCKET}/lambda/$FUNC.zip.base64sha256" --profile deploy_lambda --no-progress --acl private --content-type text/plain
  aws s3 cp "${FUNC}.zip" "s3://${AWS_S3_BUCKET}/lambda/${FUNC}.zip" --profile deploy_lambda --no-progress --acl private
done