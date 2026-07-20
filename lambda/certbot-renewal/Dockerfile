FROM public.ecr.aws/lambda/python:3.15-arm64@sha256:85102fb62ccb1ce09fad7564c5820a9e5ea2eea6dc5d1664a331e857369b4860

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
