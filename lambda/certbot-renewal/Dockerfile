FROM public.ecr.aws/lambda/python:3.15-arm64@sha256:ed067f2925879a2ea58b55c7cfc121af42f4a1e534188b136f0df68b4016bf24

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3 cryptography

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
