#!/bin/bash
#
# PROBE #3b — Intune's retry on a failing SHELL SCRIPT.
#
# ⚠ THIS IS NOT THE PROBE THAT MATTERS FOR THE DEFERRAL STRATEGY.
#
#   An Intune "Shell script" and a PKG application "pre-install script" are two
#   distinct mechanisms: the first has an explicit "Max number of times to retry
#   if script fails" setting and a frequency, the second is governed by the
#   application install retry logic.
#
#   macdeploy's deferral strategy depends on the SECOND. To measure it, use
#   `probe-app-postinstall-retry.sh`.
#
# This probe keeps its usefulness: it measures the FALLBACK PATH. If the retry
# of application pre-install scripts turns out to be unusable, the fallback is to
# deploy via a shell script, and it is then this cadence that governs everything.
#
# NO CERTIFICATE REQUIRED.
#
# DEPLOYMENT
#   Intune > Devices > macOS > Shell scripts > Add
#     - Script frequency : Every 1 hour   (to see several cycles quickly)
#     - Max number of times to retry if script fails : 3
#
# READING THE RESULT, after 24 h:
#   cat /var/log/coreupdate-probe/retry.log
#
# Each line = one invocation. The gaps between timestamps give the real cadence;
# the lines stopping give the give-up point.

set -u

PROBE_DIR="/var/log/coreupdate-probe"
mkdir -p "$PROBE_DIR"
LOGFILE="$PROBE_DIR/retry.log"
COUNTER="/var/log/coreupdate-probe/retry.count"

COUNT=0
[ -f "$COUNTER" ] && COUNT=$(cat "$COUNTER" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER"

echo "invocation=${COUNT} at=$(date -u +%Y-%m-%dT%H:%M:%SZ) exit=60" >> "$LOGFILE"
logger -s "MDT-PROBE-RETRY invocation=${COUNT}" 2>/dev/null

# 60 = our "user deferral" code. We exit non-zero to reproduce exactly what
# macdeploy will do on a deferral.
exit 60
