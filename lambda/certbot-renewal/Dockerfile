FROM public.ecr.aws/lambda/python:3.15-arm64@sha256:6141a1e79ab5cd00fda7e034e6edf64aa9f7ad9715513fb4cf0347675d7ecd9d

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3 cryptography

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
