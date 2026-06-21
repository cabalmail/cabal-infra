# SMTP sinkhole test fixture.
#
# Tiny asyncio listener that returns an operator-configurable SMTP response
# to every RCPT TO. Read /cabal/sinkhole_mode from SSM Parameter Store on
# each connection (cached 30s) and respond accordingly. See
# docs/0.9.x/sinkhole-test-harness-plan.md for the full design.
#
# Permanent fixture in dev and stage; precondition refuses prod. Reachable
# only from inside the VPC via Cloud Map (sinkhole.cabal.internal).
FROM amazonlinux:2023@sha256:d09f1353c3c0844852cff7bf103498a205532f5bca444e1ed6406e3c5402bb26

RUN dnf install -y python3 awscli-2 \
    && dnf clean all

COPY sinkhole/listener.py /usr/local/bin/listener.py
RUN chmod +x /usr/local/bin/listener.py

EXPOSE 25

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', 25)); s.close()" \
    || exit 1

ENTRYPOINT ["/usr/bin/python3", "-u", "/usr/local/bin/listener.py"]
