FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:bb768432bc397a141ea779249ab266c271d962524d543658bee10bea4fca372c

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
