# SMTP sinkhole test fixture.
#
# Tiny asyncio listener that returns an operator-configurable SMTP response
# to every RCPT TO. Read /cabal/sinkhole_mode from SSM Parameter Store on
# each connection (cached 30s) and respond accordingly. See
# docs/0.9.x/sinkhole-test-harness-plan.md for the full design.
#
# Permanent fixture in dev and stage; precondition refuses prod. Reachable
# only from inside the VPC via Cloud Map (sinkhole.cabal.internal).
FROM amazonlinux:2023@sha256:1ebfb6ca925dfc74dc7bf3513e970590df3af9ba3a9c039f8143e5c7212021a0

RUN dnf install -y python3 awscli-2 \
    && dnf clean all

COPY sinkhole/listener.py /usr/local/bin/listener.py
RUN chmod +x /usr/local/bin/listener.py

EXPOSE 25

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', 25)); s.close()" \
    || exit 1

ENTRYPOINT ["/usr/bin/python3", "-u", "/usr/local/bin/listener.py"]
