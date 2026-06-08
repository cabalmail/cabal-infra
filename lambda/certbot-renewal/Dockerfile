FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:a74b96a9f8ca97e350054386de9a5f456e817210dce620d540a63b53aeb4c44d

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
