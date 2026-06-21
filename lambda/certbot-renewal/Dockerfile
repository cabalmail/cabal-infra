FROM public.ecr.aws/lambda/python:3.14-arm64@sha256:69a7dfbefcdfabf61fc280926180c54eac28538e15f4d20647d7b90caf0ee023

RUN pip install --no-cache-dir certbot certbot-dns-route53 boto3

COPY handler.py ${LAMBDA_TASK_ROOT}/

CMD ["handler.handler"]
