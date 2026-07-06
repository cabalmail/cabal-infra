FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:30d5cd32782d6b52791c171c0edea94491f13a7962f6e3f6d15c92b5067833b8

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
