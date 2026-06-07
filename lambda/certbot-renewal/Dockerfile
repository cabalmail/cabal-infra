FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:40fd7cc36cfb67e6d64e7360da9e16eb61c5aace7630be9b83b2e6b1dda8ee9d

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
