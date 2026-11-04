#!/bin/bash
#
# PROBE #2 OF THE SPIKE — what is the real timeout of an Intune script on macOS?
#
# The Microsoft documentation is vague on this point, and the answer determines
# how long a dialog can stay on screen. If the timeout is 30 minutes, a
# `countdownSeconds` of 900 s (15 min) leaves margin; if it is 10 minutes, it
# has to be reduced.
#
# NO CERTIFICATE REQUIRED: Intune shell scripts are not signed.
#
# DEPLOYMENT
#   Intune > Devices > macOS > Shell scripts > Add
#     - Run script as signed-in user : No
#     - Hide script notifications : Yes
#     - Script frequency : Not configured (a single run)
#
# READING THE RESULT, on the test Mac:
#   log show --predicate 'eventMessage CONTAINS "MDT-PROBE-TIMEOUT"' --last 2h
#   cat /var/log/macadt-probe/timeout.log
#
# The last value written before the stop gives the real timeout to the minute.

set -u

PROBE_DIR="/var/log/macadt-probe"
mkdir -p "$PROBE_DIR"
LOGFILE="$PROBE_DIR/timeout.log"
MAX_SECONDS=5400   # 90 min: beyond that, it is no longer a relevant question
INTERVAL=15

START=$(date +%s)
echo "=== MDT-PROBE-TIMEOUT start $(date -u +%Y-%m-%dT%H:%M:%SZ) pid $$ ===" >> "$LOGFILE"

while true; do
  NOW=$(date +%s)
  ELAPSED=$((NOW - START))

  # Double write: the file survives the process stopping, the unified log lets us
  # correlate with the events of the Intune agent itself.
  echo "MDT-PROBE-TIMEOUT elapsed=${ELAPSED}s" >> "$LOGFILE"
  logger -s "MDT-PROBE-TIMEOUT elapsed=${ELAPSED}s" 2>/dev/null

  if [ "$ELAPSED" -ge "$MAX_SECONDS" ]; then
    echo "MDT-PROBE-TIMEOUT finished without being killed (>= ${MAX_SECONDS}s)" >> "$LOGFILE"
    exit 0
  fi

  sleep "$INTERVAL"
done
