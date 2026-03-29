FROM public.ecr.aws/lambda/python:3.13-arm64

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
