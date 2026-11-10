FROM public.ecr.aws/lambda/python:3.15-arm64@sha256:505a1d4216c7e32169b0b801ebcb6c9e75c4e89bd25b09eb24a1a7ffbac7f3cf

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3 cryptography

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
