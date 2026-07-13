FROM public.ecr.aws/lambda/python:3.15-arm64@sha256:ac11b9e600091cd25bd7abc850f80edf686f5c6db3eb3052b195e7b4618bfd39

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
