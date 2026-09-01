# SMTP sinkhole test fixture.
#
# Tiny asyncio listener that returns an operator-configurable SMTP response
# to every RCPT TO. Read /cabal/sinkhole_mode from SSM Parameter Store on
# each connection (cached 30s) and respond accordingly. See
# docs/0.9.x/sinkhole-test-harness-plan.md for the full design.
#
# Permanent fixture in dev and stage; precondition refuses prod. Reachable
# only from inside the VPC via Cloud Map (sinkhole.cabal.internal).
FROM amazonlinux:2023@sha256:181f98c48832fe926f8ca3b6ffeafcce128e96e77b93d08fbe9a9bc9403ce284

# AL2023 pins $releasever to the base image's own release snapshot, so
# dnf here only ever sees the package set frozen at base-image build
# time; security updates AWS publishes later are invisible, and no
# rebuild picks them up. Track the current snapshot and upgrade first.
# The upgrade is the load-bearing half: packages that ship in the base
# (openssl-libs, glib2, ...) are named in no install line below and
# would otherwise keep the base image's versions forever.
RUN echo latest > /etc/dnf/vars/releasever \
    && dnf -y upgrade \
    && dnf install -y python3 awscli-2 \
    && dnf clean all

COPY sinkhole/listener.py /usr/local/bin/listener.py
RUN chmod +x /usr/local/bin/listener.py

EXPOSE 25

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python3 -c "import socket; s=socket.socket(); s.settimeout(2); s.connect(('127.0.0.1', 25)); s.close()" \
    || exit 1

ENTRYPOINT ["/usr/bin/python3", "-u", "/usr/local/bin/listener.py"]
