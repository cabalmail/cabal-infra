FROM public.ecr.aws/lambda/python:3.13-arm64@sha256:078d4468c76c963c5159200ed15804d6f62cf2a763c5002e25dd0f6a363d26c4

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
