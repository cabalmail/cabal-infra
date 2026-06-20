FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:9888946c85720415f552fb549fc0cab2740428c4f9a9656eba9869b00d75ac07

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
