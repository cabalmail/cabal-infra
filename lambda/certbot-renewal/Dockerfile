FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:0bc3967df8beb7d8ffff61549df17a3596ac96237cdcf48abe6646a1ba62ed93

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
