#!/bin/bash
# Watches for configuration change signals via SQS and regenerates
# sendmail maps.
#
# Phase 3 will implement the full SQS-based reconfiguration loop.
set -euo pipefail

echo "[reconfigure] Not yet implemented (Phase 3)"

# Sleep indefinitely so supervisord doesn't restart in a tight loop
exec sleep infinity
